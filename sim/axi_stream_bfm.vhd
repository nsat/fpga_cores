--
-- FPGA Cores -- A(nother) HDL library
--
-- Copyright 2016 by Andre Souto (suoto)
--
-- This file is part of FPGA Cores.
--
-- FPGA Cores is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- FPGA Cores is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with FPGA Cores.  If not, see <http://www.gnu.org/licenses/>.

---------------------------------
-- Block name and description --
--------------------------------

---------------
-- Libraries --
---------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;

library osvvm;
use osvvm.RandomPkg.all;

library str_format;
use str_format.str_format_pkg.all;

library fpga_cores;
use fpga_cores.common_pkg.all;

use work.testbench_utils_pkg.all;
use work.axi_stream_bfm_pkg.all;

------------------------
-- Entity declaration --
------------------------
entity axi_stream_bfm is
  generic (
    NAME       : string := AXI_STREAM_MASTER_DEFAULT_NAME;
    DATA_WIDTH : natural := 16;
    USER_WIDTH : natural := 0;
    ID_WIDTH   : natural := 0);
  port (
    -- Usual ports
    clk      : in  std_logic;
    rst      : in  std_logic;
    -- AXI stream output
    m_tready : in  std_logic;
    m_tdata  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
    m_tuser  : out std_logic_vector(USER_WIDTH - 1 downto 0);
    m_tkeep  : out std_logic_vector((DATA_WIDTH + 7) / 8 - 1 downto 0) := (others => '0');
    m_tid    : out std_logic_vector(ID_WIDTH - 1 downto 0) := (others => '0');
    m_tvalid : out std_logic;
    m_tlast  : out std_logic);
end axi_stream_bfm;

architecture axi_stream_bfm of axi_stream_bfm is

  function infer_mask ( constant v : std_logic_vector ) return std_logic_vector is
    constant bytes  : natural := (v'length + 7) / 8;
    variable result : std_logic_vector(bytes - 1 downto 0) := (others => '0');
  begin
    for byte in 0 to bytes - 1 loop
      -- Mark as valid bytes whose value is anything other than a full undefined byte
      if v(8*(byte + 1) - 1 downto 8*byte) = (8*(byte + 1) - 1 downto 8*byte => 'U') then
        exit;
      else
        result(byte) := '1';
      end if;
    end loop;

    -- If all bytes were valid, force all ones
    if result = (result'range => '0') then
      return (result'range => '1');
    end if;

    return result;
  end;

  subtype user_array_t is std_logic_vector_2d_t(open)(USER_WIDTH - 1 downto 0);

  ---------------
  -- Constants --
  ---------------
  constant self            : actor_t  := new_actor(NAME);
  constant logger          : logger_t := get_logger(NAME);

  constant DATA_BYTE_WIDTH : natural := (DATA_WIDTH + 7) / 8;

  -------------
  -- Signals --
  -------------
  signal wr_en           : boolean := True;
  signal cfg_probability : real range 0.0 to 1.0 := 1.0;

begin

  -------------------
  -- Port mappings --
  -------------------

  ------------------------------
  -- Asynchronous assignments --
  ------------------------------

  ---------------
  -- Processes --
  ---------------
  main_p : process
    variable msg : msg_t;

    ------------------------------------------------------------------
    procedure write (
      constant data : std_logic_vector(DATA_WIDTH - 1 downto 0);
      constant user : std_logic_vector(USER_WIDTH - 1 downto 0);
      constant mask : std_logic_vector(DATA_BYTE_WIDTH - 1 downto 0);
      variable id   : std_logic_vector(ID_WIDTH - 1 downto 0);
      constant last : boolean := False) is
    begin
      debug(sformat("Writing: %r %r %s", fo(data), fo(mask), fo(last)));

      if not wr_en then
        wait until wr_en;
      end if;

      m_tdata   <= data;
      m_tuser   <= user;
      m_tkeep   <= mask;
      m_tid     <= id;
      m_tvalid  <= '1';
      if last then
        m_tlast <= '1';
      end if;

      wait until m_tvalid = '1' and m_tready = '1' and rising_edge(clk);

      m_tdata  <= (others => 'U');
      m_tuser  <= (others => 'U');
      m_tkeep  <= (others => 'U');
      m_tid    <= (others => 'U');
      m_tvalid <= '0';
      m_tlast  <= '0';
    end;

    ------------------------------------------------------------------------------------
    procedure write_data (
      constant data        : byte_array_t;
      constant user        : user_array_t;
      constant probability : real range 0.0 to 1.0 := 1.0;
      constant tid         : std_logic_vector(ID_WIDTH - 1 downto 0)
   ) is
      variable write_user  : std_logic_vector(USER_WIDTH - 1 downto 0);
      variable write_id    : std_logic_vector(ID_WIDTH - 1 downto 0);
      variable word        : std_logic_vector(DATA_WIDTH - 1 downto 0);
      variable word_index  : natural := 0;
      variable byte        : natural;

    begin

      if cfg_probability /= probability then
        info(
          logger,
          sformat(
            "Updating probability: %d\% to %d\%",
            fo(integer(100.0*cfg_probability)),
            fo(integer(100.0*probability))
          )
        );

        cfg_probability <= probability;
      end if;

      write_id := tid;

      for i in 0 to data'length - 1 loop
        byte  := i mod DATA_BYTE_WIDTH;

        word(8*(byte + 1) - 1 downto 8*byte) := data(i);

        if ((i + 1) mod DATA_BYTE_WIDTH) = 0 then
          -- Only try to get user if there's such port in the first place. Also allow
          -- user to have less entries than data.
          if USER_WIDTH > 0 and word_index < user'length then
            write_user := user(word_index);
            word_index := word_index + 1;
          end if;

          if i /= data'length - 1 then
            write(word, write_user, (others => '0'), write_id, False);
          else
            write(word, write_user, infer_mask(word), write_id, True);
          end if;

          word       := (others => 'U');
          write_user := (others => 'U');
          write_id   := (others => 'U');
        end if;
      end loop;

      assert word = (word'range => 'U')
        report "This shouldn't really happen should it"
        severity Failure;

    end;

    ------------------------------------------------------------------------------------
    procedure handle_frame_user ( constant frame : axi_stream_tuser_frame_t ) is
      variable data : byte_array_t(frame.data'range);
      variable user : user_array_t(frame.data'range);
    begin
      -- Convert a list of tuples into two lists
      for i in frame.data'range loop
        data(i) := frame.data(i).data;
        user(i) := frame.data(i).user;
      end loop;

      write_data(
        data        => data,
        user        => user,
        probability => frame.probability,
        tid         => frame.id
      );

    end;

    ------------------------------------------------------------------------------------
    procedure handle_frame ( constant frame : axi_stream_frame_t ) is
      variable word : std_logic_vector(DATA_WIDTH - 1 downto 0);
      variable id   : std_logic_vector(ID_WIDTH - 1 downto 0);
      variable byte : natural;
    begin

      info(logger, "Handling frame with data only");

      write_data(
        data        => reinterpret(frame.data, 8),
        user        => (0 to 0 => (USER_WIDTH - 1 downto 0 => 'U')),
        probability => frame.probability,
        tid         => frame.id
      );

    end;

    ------------------------------------------------------------------------------------

  begin
    m_tvalid <= '0';
    m_tlast <= '0';

    receive(net, self, msg);
    if USER_WIDTH = 0 then
      handle_frame(pop(msg));
    else
      handle_frame_user(pop(msg));
    end if;
    acknowledge(net, msg);

  end process;

  duty_cycle_p : process(clk, rst)
    variable rand : RandomPType;
  begin
    if rst = '1' then
      rand.InitSeed(name);
      wr_en <= False;
    elsif rising_edge(clk) then
      wr_en <= rand.RandReal(1.0) < cfg_probability;
    end if;
  end process;

end axi_stream_bfm;
