# Redis test suite. Copyright (C) 2009 Salvatore Sanfilippo antirez@gmail.com
# This software is released under the BSD License. See the COPYING file for
# more information.

package require Tcl 8.5

# 第一步，引入其他的tcl脚本文件和定义全局变量
# 首先使用 source 关键字，引入tests目录下support子录中的redis.tcl. server.tcl 等脚本文件。
# 这些脚本文件实现了单元测试框架所需的部分功能，比如server.tcl脚本文件中，就实现了启动
# Redis测试实例的子函数start server,而redis.tcl脚本中实现了向测试用Redis实例发送命令的子函数。

# 而除了引入脚本文件之外，第一步操作还包括了定义全局变量。比如，测试框架定义了一个全局变量::all_tests,
# 这个全局变量包含了所有预定义的单元测试。如果我们不加任何参数运行 test_helper.tcl 时，测试框架就会
# 运行::all_ tests定义的所有测试。此外,第一步定义的全局变量，还包括测试用主机IP、端口号、跳过的测试用例集合、单一测试的用例集合,等。
set tcl_precision 17
source tests/support/redis.tcl
source tests/support/server.tcl
source tests/support/tmpfile.tcl
source tests/support/test.tcl
source tests/support/util.tcl

set ::all_tests {
    unit/printver
    unit/dump
    unit/auth
    unit/protocol
    unit/keyspace
    unit/scan
    unit/type/string
    unit/type/incr
    unit/type/list
    unit/type/list-2
    unit/type/list-3
    unit/type/set
    unit/type/zset
    unit/type/hash
    unit/type/stream
    unit/type/stream-cgroups
    unit/sort
    unit/expire
    unit/other
    unit/multi
    unit/quit
    unit/aofrw
    integration/block-repl
    integration/replication
    integration/replication-2
    integration/replication-3
    integration/replication-4
    integration/replication-psync
    integration/aof
    integration/rdb
    integration/convert-zipmap-hash-on-load
    integration/logging
    integration/psync2
    integration/psync2-reg
    unit/pubsub
    unit/slowlog
    unit/scripting
    unit/maxmemory
    unit/introspection
    unit/introspection-2
    unit/limits
    unit/obuf-limits
    unit/bitops
    unit/bitfield
    unit/geo
    unit/memefficiency
    unit/hyperloglog
    unit/lazyfree
    unit/wait
    unit/pendingquerybuf
}
# Index to the next test to run in the ::all_tests list.
set ::next_test 0

set ::host 127.0.0.1
set ::port 21111
set ::traceleaks 0
set ::valgrind 0
set ::stack_logging 0
set ::verbose 0
set ::quiet 0
set ::denytags {}
set ::skiptests {}
set ::allowtags {}
set ::only_tests {}
set ::single_tests {}
set ::skip_till ""
set ::external 0; # If "1" this means, we are running against external instance
set ::file ""; # If set, runs only the tests in this comma separated list
set ::curfile ""; # Hold the filename of the current suite
set ::accurate 0; # If true runs fuzz tests with more iterations
set ::force_failure 0
set ::timeout 600; # 10 minutes without progresses will quit the test.
set ::last_progress [clock seconds]
set ::active_servers {} ; # Pids of active Redis instances.
set ::dont_clean 0
set ::wait_server 0
set ::stop_on_failure 0
set ::loop 0

# Set to 1 when we are running in client mode. The Redis test uses a
# server-client model to run tests simultaneously. The server instance
# runs the specified number of client instances that will actually run tests.
# The server is responsible of showing the result to the user, and exit with
# the appropriate exit code depending on the test outcome.
set ::client 0
set ::numclients 16
# 这个函数比较简单,它就是根据传入的测试用例名，用source命令把tests录下，
# 该用例对应的tcl 脚本文件引入并执行。最后,给测试server发送"done" 的消息。
proc execute_tests name {
    set path "tests/$name.tcl"
    set ::curfile $path
    source $path
    send_data_packet $::test_server_fd done "$name"
}

# Setup a list to hold a stack of server configs. When calls to start_server
# are nested, use "srv 0 pid" to get the pid of the inner server. To access
# outer servers, use "srv -1 pid" etcetera.
set ::servers {}
proc srv {args} {
    set level 0
    if {[string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set property [lindex $args 1]
    } else {
        set property [lindex $args 0]
    }
    set srv [lindex $::servers end+$level]
    dict get $srv $property
}

# Provide easy access to the client for the inner server. It's possible to
# prepend the argument list with a negative level to access clients for
# servers running in outer blocks.
proc r {args} {
    set level 0
    if {[string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set args [lrange $args 1 end]
    }
    [srv $level "client"] {*}$args
}

proc reconnect {args} {
    set level [lindex $args 0]
    if {[string length $level] == 0 || ![string is integer $level]} {
        set level 0
    }

    set srv [lindex $::servers end+$level]
    set host [dict get $srv "host"]
    set port [dict get $srv "port"]
    set config [dict get $srv "config"]
    set client [redis $host $port]
    dict set srv "client" $client

    # select the right db when we don't have to authenticate
    if {![dict exists $config "requirepass"]} {
        $client select 9
    }

    # re-set $srv in the servers list
    lset ::servers end+$level $srv
}

proc redis_deferring_client {args} {
    set level 0
    if {[llength $args] > 0 && [string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set args [lrange $args 1 end]
    }

    # create client that defers reading reply
    set client [redis [srv $level "host"] [srv $level "port"] 1]

    # select the right db and read the response (OK)
    $client select 9
    $client read
    return $client
}

# Provide easy access to INFO properties. Same semantic as "proc r".
proc s {args} {
    set level 0
    if {[string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set args [lrange $args 1 end]
    }
    status [srv $level "client"] [lindex $args 0]
}

proc cleanup {} {
    if {$::dont_clean} {
        return
    }
    if {!$::quiet} {puts -nonewline "Cleanup: may take some time... "}
    flush stdout
    catch {exec rm -rf {*}[glob tests/tmp/redis.conf.*]}
    catch {exec rm -rf {*}[glob tests/tmp/server.*]}
    if {!$::quiet} {puts "OK"}
}

proc test_server_main {} {
    cleanup
    set tclsh [info nameofexecutable]
    # Open a listening socket, trying different ports in order to find a
    # non busy one.
    set port [find_available_port 11111]
    if {!$::quiet} {
        puts "Starting test server at port $port"
    }
#   首先，它会使用socket -server命令启动一个测试server。这个测试server会创建一个
#   socket,监听来自测试客户端的消息。那么,一旦有客户端连接时,测试server会执行
#   accept_test_clients 函数

    socket -server accept_test_clients -myaddr 127.0.0.1 $port

    # Start the client instances
#   第二步，它会开始启动测试客户端。
#   test_server_main函数会执行一个for循环流程，在这个循环流程中，它会根据要启动的测
#   试客户端数量，依次调用exec命令,执行tcl脚本。这里的测试客户端数量是由全局变量::numclients决定的，
#   默认值是16。而执行的tcl脚本,正是当前运行的test_helper.tcl 脚本，参数也和当前脚本的参数一样,
#   并且还加上了"-client" 参数,表示当前启动的是测试客户端。

    set ::clients_pids {}
    set start_port [expr {$::port+100}]
    for {set j 0} {$j < $::numclients} {incr j} {
        # 设定测试客户端端口
        set start_port [find_available_port $start_port]
        # 使用exec命令执行test_helper.tcl脚本，脚本参数跟当前参数一致，增加client参数，会执行test_client_main函数
        set p [exec $tclsh [info script] {*}$::argv \
            --client $port --port $start_port &]
        # 记录每个测试客户端脚本运行的进程号
        lappend ::clients_pids $p
        # 递增测试客户端的端口号
        incr start_port 10
    }

    # Setup global state for the test server
    set ::idle_clients {}
    set ::active_clients {}
    array set ::active_clients_task {}
    array set ::clients_start_time {}
    set ::clients_time_history {}
    set ::failed_tests {}

    # Enter the event loop to handle clients I/O
    # 在启动了测试客户端后，每隔10s周期性地执行一次 test_server_cron 函数。
    # 而这个函数的主要工作是，当测试执行超时的时候，输出报错信息,并清理测试客户端和测试server.

    after 100 test_server_cron
    vwait forever
}

# This function gets called 10 times per second.
proc test_server_cron {} {
    set elapsed [expr {[clock seconds]-$::last_progress}]

    if {$elapsed > $::timeout} {
        set err "\[[colorstr red TIMEOUT]\]: clients state report follows."
        puts $err
        lappend ::failed_tests $err
        show_clients_state
        kill_clients
        force_kill_all_servers
        the_end
    }

    after 100 test_server_cron
}
#   对于 accept_test_clients 函数来说，它会调用filevent命令,监听客户端连接上是否有读事
#   件发生。如果有读事件发生,这也就表示客户端有消息发送给测试server.那么,它会执行 read_from_test_client
proc accept_test_clients {fd addr port} {
    fconfigure $fd -encoding binary
    fileevent $fd readable [list read_from_test_client $fd]
}

# This is the readable handler of our test server. Clients send us messages
# in the form of a status code such and additional data. Supported
# status types are:
#
# ready: the client is ready to execute the command. Only sent at client
#        startup. The server will queue the client FD in the list of idle
#        clients.
# testing: just used to signal that a given test started.
# ok: a test was executed with success.
# err: a test was executed with an error.
# skip: a test was skipped by skipfile or individual test options.
# ignore: a test was skipped by a group tag.
# exception: there was a runtime exception while executing the test.
# done: all the specified test file was processed, this test client is
#       ready to accept a new task.

# read_from_test_client 函数，会根据测试客户端发送的不同消息来执行不同的代码分支。
# 比如，当测试客户端发送的消息是"ready" ，这就表明当前客户端是空闲的，那么,测试
# server可以把未完成的测试用例再发给这个客户端执行，这个过程是由signal_idle_client 函数来完成的

# 再比如，当测试客户端发送的消息是"done" 时，read_from_test_client 函数会统计当前已经
# 完成的测试用例数量，而且也会调用signal_idle_client 函数,让当前客户端继续执行未完
# 成的测试用例。

proc read_from_test_client fd {
    set bytes [gets $fd]
    set payload [read $fd $bytes]
    foreach {status data} $payload break
    set ::last_progress [clock seconds]

    if {$status eq {ready}} {
        if {!$::quiet} {
            puts "\[$status\]: $data"
        }
        signal_idle_client $fd
    } elseif {$status eq {done}} {
        set elapsed [expr {[clock seconds]-$::clients_start_time($fd)}]
        set all_tests_count [llength $::all_tests]
        set running_tests_count [expr {[llength $::active_clients]-1}]
        set completed_tests_count [expr {$::next_test-$running_tests_count}]
        puts "\[$completed_tests_count/$all_tests_count [colorstr yellow $status]\]: $data ($elapsed seconds)"
        lappend ::clients_time_history $elapsed $data
        signal_idle_client $fd
        set ::active_clients_task($fd) DONE
    } elseif {$status eq {ok}} {
        if {!$::quiet} {
            puts "\[[colorstr green $status]\]: $data"
        }
        set ::active_clients_task($fd) "(OK) $data"
    } elseif {$status eq {skip}} {
        if {!$::quiet} {
            puts "\[[colorstr yellow $status]\]: $data"
        }
    } elseif {$status eq {ignore}} {
        if {!$::quiet} {
            puts "\[[colorstr cyan $status]\]: $data"
        }
    } elseif {$status eq {err}} {
        set err "\[[colorstr red $status]\]: $data"
        puts $err
        lappend ::failed_tests $err
        set ::active_clients_task($fd) "(ERR) $data"
            if {$::stop_on_failure} {
            puts -nonewline "(Test stopped, press enter to continue)"
            flush stdout
            gets stdin
        }
    } elseif {$status eq {exception}} {
        puts "\[[colorstr red $status]\]: $data"
        kill_clients
        force_kill_all_servers
        exit 1
    } elseif {$status eq {testing}} {
        set ::active_clients_task($fd) "(IN PROGRESS) $data"
    } elseif {$status eq {server-spawned}} {
        lappend ::active_servers $data
    } elseif {$status eq {server-killed}} {
        set ::active_servers [lsearch -all -inline -not -exact $::active_servers $data]
    } else {
        if {!$::quiet} {
            puts "\[$status\]: $data"
        }
    }
}

proc show_clients_state {} {
    # The following loop is only useful for debugging tests that may
    # enter an infinite loop. Commented out normally.
    foreach x $::active_clients {
        if {[info exist ::active_clients_task($x)]} {
            puts "$x => $::active_clients_task($x)"
        } else {
            puts "$x => ???"
        }
    }
}

proc kill_clients {} {
    foreach p $::clients_pids {
        catch {exec kill $p}
    }
}

proc force_kill_all_servers {} {
    foreach p $::active_servers {
        puts "Killing still running Redis server $p"
        catch {exec kill -9 $p}
    }
}

# A new client is idle. Remove it from the list of active clients and
# if there are still test units to run, launch them.
proc signal_idle_client fd {
    # Remove this fd from the list of active clients.
    set ::active_clients \
        [lsearch -all -inline -not -exact $::active_clients $fd]

    if 0 {show_clients_state}

    # New unit to process?
    if {$::next_test != [llength $::all_tests]} {
        if {!$::quiet} {
            puts [colorstr bold-white "Testing [lindex $::all_tests $::next_test]"]
            set ::active_clients_task($fd) "ASSIGNED: $fd ([lindex $::all_tests $::next_test])"
        }
        set ::clients_start_time($fd) [clock seconds]
        send_data_packet $fd run [lindex $::all_tests $::next_test]
        lappend ::active_clients $fd
        incr ::next_test
        if {$::loop && $::next_test == [llength $::all_tests]} {
            set ::next_test 0
        }
    } else {
        lappend ::idle_clients $fd
        if {[llength $::active_clients] == 0} {
            the_end
        }
    }
}

# The the_end function gets called when all the test units were already
# executed, so the test finished.
proc the_end {} {
    # TODO: print the status, exit with the rigth exit code.
    puts "\n                   The End\n"
    puts "Execution time of different units:"
    foreach {time name} $::clients_time_history {
        puts "  $time seconds - $name"
    }
    if {[llength $::failed_tests]} {
        puts "\n[colorstr bold-red {!!! WARNING}] The following tests failed:\n"
        foreach failed $::failed_tests {
            puts "*** $failed"
        }
        cleanup
        exit 1
    } else {
        puts "\n[colorstr bold-white {\o/}] [colorstr bold-green {All tests passed without errors!}]\n"
        cleanup
        exit 0
    }
}

# The client is not even driven (the test server is instead) as we just need
# to read the command, execute, reply... all this in a loop.

# test_client_main函数在执行时，会先向测试server发送一个 "ready" 的消息。
# 测试server一旦监听到有客户端连接发送了"ready" 消息，它就会通过
# signal_idle_client 函数,把未完成的单元测试发送给这个客户端。
# 具体来说，signal_idle_client 函数会发送 "run 测试用例名" 这样的消息给客户端。比如，
# 当前未完成的测试用例是unit/type/string,那么 signal_idle_client 函数就会发送"run
# unit/type/string"消息给测试客户端。

proc test_client_main server_port {
    set ::test_server_fd [socket localhost $server_port]
    fconfigure $::test_server_fd -encoding binary
    send_data_packet $::test_server_fd ready [pid]

# test_client_main 函数在发送了"ready" 消息之后，就会执行一个while循环流
# 程,等待从测试server读取消息。等它收到测试server返回的"run 测试用例名" 的消息
# 时，它就会调用execute_tests 函数,执行相应的测试用例。
    while 1 {
        set bytes [gets $::test_server_fd]
        set payload [read $::test_server_fd $bytes]
        foreach {cmd data} $payload break
        if {$cmd eq {run}} {
            execute_tests $data
        } else {
            error "Unknown test client command: $cmd"
        }
    }
}

proc send_data_packet {fd status data} {
    set payload [list $status $data]
    puts $fd [string length $payload]
    puts -nonewline $fd $payload
    flush $fd
}

proc print_help_screen {} {
    puts [join {
        "--valgrind         Run the test over valgrind."
        "--stack-logging    Enable OSX leaks/malloc stack logging."
        "--accurate         Run slow randomized tests for more iterations."
        "--quiet            Don't show individual tests."
        "--single <unit>    Just execute the specified unit (see next option). this option can be repeated."
        "--list-tests       List all the available test units."
        "--only <test>      Just execute the specified test by test name. this option can be repeated."
        "--skip-till <unit> Skip all units until (and including) the specified one."
        "--clients <num>    Number of test clients (default 16)."
        "--timeout <sec>    Test timeout in seconds (default 10 min)."
        "--force-failure    Force the execution of a test that always fails."
        "--config <k> <v>   Extra config file argument."
        "--skipfile <file>  Name of a file containing test names that should be skipped (one per line)."
        "--dont-clean       Don't delete redis log files after the run."
        "--stop             Blocks once the first test fails."
        "--loop             Execute the specified set of tests forever."
        "--wait-server      Wait after server is started (so that you can attach a debugger)."
        "--help             Print this help screen."
    } "\n"]
}

# parse arguments
#   第二步，解析脚本参数
#   这一步操作是一个for循环,它会在test_helper.tcl脚本引入其他脚本和定义全局变量后,接着执行。
#   这个循环流程本身并不复杂，它的目的就是逐一解析 test_helper.tcl 脚本执行时携带的参数。
#   那么，在解析参数过程中，如果test_helper.tcl 脚本带有 "single" 参数，就表示脚本并不
#   是执行所有测试用例，而只是执行一个或多个测试用例。因此,脚本中的全局变量::single_tests, 
#   就会保存这些测试用例，并且把全局变量 ::all_tests设置为::single_tests的值, 表示就
#   执行::single_tests中的测试用例

for {set j 0} {$j < [llength $argv]} {incr j} {
    set opt [lindex $argv $j]
    set arg [lindex $argv [expr $j+1]]
    if {$opt eq {--tags}} {
        foreach tag $arg {
            if {[string index $tag 0] eq "-"} {
                lappend ::denytags [string range $tag 1 end]
            } else {
                lappend ::allowtags $tag
            }
        }
        incr j
    } elseif {$opt eq {--config}} {
        set arg2 [lindex $argv [expr $j+2]]
        lappend ::global_overrides $arg
        lappend ::global_overrides $arg2
        incr j 2
    } elseif {$opt eq {--skipfile}} {
        incr j
        set fp [open $arg r]
        set file_data [read $fp]
        close $fp
        set ::skiptests [split $file_data "\n"]
    } elseif {$opt eq {--valgrind}} {
        set ::valgrind 1
    } elseif {$opt eq {--stack-logging}} {
        if {[string match {*Darwin*} [exec uname -a]]} {
            set ::stack_logging 1
        }
    } elseif {$opt eq {--quiet}} {
        set ::quiet 1
    } elseif {$opt eq {--host}} {
        set ::external 1
        set ::host $arg
        incr j
    } elseif {$opt eq {--port}} {
        set ::port $arg
        incr j
    } elseif {$opt eq {--accurate}} {
        set ::accurate 1
    } elseif {$opt eq {--force-failure}} {
        set ::force_failure 1
    } elseif {$opt eq {--single}} {
        lappend ::single_tests $arg
        incr j
    } elseif {$opt eq {--only}} {
        lappend ::only_tests $arg
        incr j
    } elseif {$opt eq {--skip-till}} {
        set ::skip_till $arg
        incr j
    } elseif {$opt eq {--list-tests}} {
        foreach t $::all_tests {
            puts $t
        }
        exit 0
    } elseif {$opt eq {--verbose}} {
        set ::verbose 1
    } elseif {$opt eq {--client}} {
        set ::client 1
        set ::test_server_port $arg
        incr j
    } elseif {$opt eq {--clients}} {
        set ::numclients $arg
        incr j
    } elseif {$opt eq {--dont-clean}} {
        set ::dont_clean 1
    } elseif {$opt eq {--wait-server}} {
        set ::wait_server 1
    } elseif {$opt eq {--stop}} {
        set ::stop_on_failure 1
    } elseif {$opt eq {--loop}} {
        set ::loop 1
    } elseif {$opt eq {--timeout}} {
        set ::timeout $arg
        incr j
    } elseif {$opt eq {--help}} {
        print_help_screen
        exit 0
    } else {
        puts "Wrong argument: $opt"
        exit 1
    }
}

# If --skil-till option was given, we populate the list of single tests
# to run with everything *after* the specified unit.
if {$::skip_till != ""} {
    set skipping 1
    foreach t $::all_tests {
        if {$skipping == 0} {
            lappend ::single_tests $t
        }
        if {$t == $::skip_till} {
            set skipping 0
        }
    }
    if {$skipping} {
        puts "test $::skip_till not found"
        exit 0
    }
}

# Override the list of tests with the specific tests we want to run
# in case there was some filter, that is --single or --skip-till options.
if {[llength $::single_tests] > 0} {
    set ::all_tests $::single_tests
}

proc attach_to_replication_stream {} {
    set s [socket [srv 0 "host"] [srv 0 "port"]]
    fconfigure $s -translation binary
    puts -nonewline $s "SYNC\r\n"
    flush $s

    # Get the count
    while 1 {
        set count [gets $s]
        set prefix [string range $count 0 0]
        if {$prefix ne {}} break; # Newlines are allowed as PINGs.
    }
    if {$prefix ne {$}} {
        error "attach_to_replication_stream error. Received '$count' as count."
    }
    set count [string range $count 1 end]

    # Consume the bulk payload
    while {$count} {
        set buf [read $s $count]
        set count [expr {$count-[string length $buf]}]
    }
    return $s
}

proc read_from_replication_stream {s} {
    fconfigure $s -blocking 0
    set attempt 0
    while {[gets $s count] == -1} {
        if {[incr attempt] == 10} return ""
        after 100
    }
    fconfigure $s -blocking 1
    set count [string range $count 1 end]

    # Return a list of arguments for the command.
    set res {}
    for {set j 0} {$j < $count} {incr j} {
        read $s 1
        set arg [::redis::redis_bulk_read $s]
        if {$j == 0} {set arg [string tolower $arg]}
        lappend res $arg
    }
    return $res
}

proc assert_replication_stream {s patterns} {
    for {set j 0} {$j < [llength $patterns]} {incr j} {
        assert_match [lindex $patterns $j] [read_from_replication_stream $s]
    }
}

proc close_replication_stream {s} {
    close $s
}

# With the parallel test running multiple Redis instances at the same time
# we need a fast enough computer, otherwise a lot of tests may generate
# false positives.
# If the computer is too slow we revert the sequential test without any
# parallelism, that is, clients == 1.
proc is_a_slow_computer {} {
    set start [clock milliseconds]
    for {set j 0} {$j < 1000000} {incr j} {}
    set elapsed [expr [clock milliseconds]-$start]
    expr {$elapsed > 200}
}
#   第三步，启动测试流程
#   在这一步, test_helper.tcl 脚本会判断全局变量::client的值,而这个值表示是否启动测试
#   客户端。如果::client的值为0,那么就表明当前不是启动测试客户端，因此,test_helper.tcl 
#   脚本会来执行test_server_main函数。否则的话，test_helper.tcl 脚本会执行test_client_main函数

if {$::client} {
    if {[catch { test_client_main $::test_server_port } err]} {
        set estr "Executing test client: $err.\n$::errorInfo"
        if {[catch {send_data_packet $::test_server_fd exception $estr}]} {
            puts $estr
        }
        exit 1
    }
} else {
    if {[is_a_slow_computer]} {
        puts "** SLOW COMPUTER ** Using a single client to avoid false positives."
        set ::numclients 1
    }

    if {[catch { test_server_main } err]} {
        if {[string length $err] > 0} {
            # only display error when not generated by the test suite
            if {$err ne "exception"} {
                puts $::errorInfo
            }
            exit 1
        }
    }
}
