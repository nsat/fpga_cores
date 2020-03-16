--
-- DVB IP
--
-- Copyright 2019 by Suoto <andre820@gmail.com>
--
-- This file is part of the DVB IP.
--
-- DVB IP is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- DVB IP is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with DVB IP.  If not, see <http://www.gnu.org/licenses/>.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;

library str_format;
use str_format.str_format_pkg.all;

use work.common_pkg.all;
use work.testbench_utils_pkg.all;

package axi_stream_bfm_pkg is

  constant AXI_STREAM_MASTER_DEFAULT_NAME : string := "axi_stream_master_bfm";

  -- This is the user content
  type axi_stream_frame_t is record
    data        : std_logic_vector_2d_t;
    id          : std_logic_vector;
    probability : real range 0.0 to 1.0;
  end record;

  type axi_stream_bfm_t is record
    dest        : actor_t;
    sender      : actor_t;
    outstanding : natural;
    logger      : logger_t;
  end record;

  procedure push(msg : msg_t; frame : axi_stream_frame_t);
  impure function pop(msg : msg_t) return axi_stream_frame_t;

  impure function create_bfm (
    constant reader_name : in string := AXI_STREAM_MASTER_DEFAULT_NAME )
  return axi_stream_bfm_t;

  procedure bfm_write (
    signal   net         : inout std_logic;
    variable bfm         : inout axi_stream_bfm_t;
    constant data        : std_logic_vector_2d_t;
    constant id          : std_logic_vector;
    constant probability : real := 1.0;
    constant blocking    : boolean := True);

  procedure wait_outstanding (
    signal   net : inout std_logic;
    variable bfm : inout axi_stream_bfm_t );

end axi_stream_bfm_pkg;

package body axi_stream_bfm_pkg is

  impure function create_bfm (
    constant reader_name : in string := AXI_STREAM_MASTER_DEFAULT_NAME ) return axi_stream_bfm_t is
    variable bfm         : axi_stream_bfm_t;
    constant sender_name : string := "axi_stream_bfm_t(" & reader_name & ")";
  begin
    return (dest      => find(reader_name),
            sender      => new_actor(sender_name),
            outstanding => 0,
            logger      => get_logger(sender_name));
  end;

  procedure push(msg : msg_t; frame : axi_stream_frame_t ) is
  begin
    info(sformat("Pushing ID %r, data is %d x %d", fo(frame.id), fo(frame.data'length), fo(frame.data(0)'length)));
    push(msg, frame.probability);
    push(msg, frame.id);
    push(msg, frame.data);
  end;

  impure function pop(msg : msg_t) return axi_stream_frame_t is
    constant probability : real             := pop(msg);
    constant id         : std_logic_vector := pop(msg);
  begin
    info(sformat("Popped ID %r", fo(id)));
    return axi_stream_frame_t'(
      id          => id,
      data        => pop(msg),
      probability => probability
    );
  end;

  procedure wait_reply (
    signal   net : inout std_logic;
    variable bfm : inout axi_stream_bfm_t ) is
    variable msg : msg_t := new_msg(sender => bfm.sender);
  begin
    receive(net, bfm.sender, msg);
    assert pop(msg);
    bfm.outstanding := bfm.outstanding - 1;
  end;

  procedure wait_outstanding (
    signal   net : inout std_logic;
    variable bfm : inout axi_stream_bfm_t ) is
  begin
    while bfm.outstanding /= 0 loop
      wait_reply(net, bfm);
    end loop;
  end;

  procedure bfm_write (
    signal   net         : inout std_logic;
    variable bfm         : inout axi_stream_bfm_t;
    constant data        : std_logic_vector_2d_t;
    constant id          : std_logic_vector;
    constant probability : real := 1.0;
    constant blocking    : boolean := True) is
    variable msg         : msg_t := new_msg(sender => bfm.sender);
  begin
    msg := new_msg(sender => bfm.sender);
    push(
      msg,
      axi_stream_frame_t'(
        data        => data,
        id          => id,
        probability => probability
      )
    );

    bfm.outstanding := bfm.outstanding + 1;

    send(net, bfm.dest, msg);

    if not blocking then
      return;
    end if;

    wait_reply(net, bfm);
  end;

end package body;
