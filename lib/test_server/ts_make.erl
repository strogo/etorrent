%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%% 
%%     $Id$
%%
-module(ts_make).

-export([make/1,make/2,unmake/1]).

-include("test_server.hrl").

%% Functions to be called from make test cases.

make(Config) when list(Config) ->
    DataDir = ?config(data_dir, Config),
    Makefile = ?config(makefile, Config),
    case make(DataDir, Makefile) of
	ok -> ok;
	{error,Reason} -> ?t:fail({make_failed,Reason})
    end.

unmake(Config) when list(Config) ->
    ok.

%% Runs `make' in the given directory.
%% Result: ok | {error, Reason}

make(Dir, Makefile) ->
    {RunFile, RunCmd, Script} = run_make_script(os:type(), Dir, Makefile),
    case file:write_file(RunFile, Script) of
	ok ->
	    Log = filename:join(Dir, "make.log"),
	    file:delete(Log),
	    Port = open_port({spawn, RunCmd}, [eof,stream,in,stderr_to_stdout]),
	    case get_port_data(Port, [], false) of
		"*ok*" ++ _ -> ok;
		"*error*" ++ _ -> {error, make};
		Other ->{error,{make,Other}}
	    end;
	Error -> Error
    end.

get_port_data(Port, Last0, Complete0) ->
    receive
	{Port,{data,Bytes}} ->
	    {Last, Complete} = update_last(Bytes, Last0, Complete0),
	    get_port_data(Port, Last, Complete);
	{Port, eof} ->
	    Result = update_last(eof, Last0, Complete0),
	    unlink(Port),
	    exit(Port, die),
	    Result
    end.

update_last([C|Rest], Line, true) ->
    io:put_chars(Line),
    io:nl(),
    update_last([C|Rest], [], false);
update_last([$\r|Rest], Result, Complete) ->
    update_last(Rest, Result, Complete);
update_last([$\n|Rest], Result, _Complete) ->
    update_last(Rest, lists:reverse(Result), true);
update_last([C|Rest], Result, Complete) ->
    update_last(Rest, [C|Result], Complete);
update_last([], Result, Complete) ->
    {Result, Complete};
update_last(eof, Result, _) ->
    Result.

run_make_script({win32, _}, Dir, Makefile) ->
    {"run_make.bat",
     ".\\run_make",
     ["@echo off\r\n",
      "cd ", filename:nativename(Dir), "\r\n",
      "nmake -nologo -f ", Makefile, " \r\n",
      "if errorlevel 1 echo *error*\r\n",
      "if not errorlevel 1 echo *ok*\r\n"]};
run_make_script({unix, _}, Dir, Makefile) ->
    {"run_make", 
     "/bin/sh ./run_make",
     ["#!/bin/sh\n",
      "cd ", Dir, "\n",
      "make -f ", Makefile, " 2>&1\n",
      "case $? in\n",
      "  0) echo '*ok*';;\n",
      "  *) echo '*error*';;\n",
      "esac\n"]};
run_make_script(_Other, _Dir, _Makefile) ->
    exit(dont_know_how_to_make_script_on_this_platform).