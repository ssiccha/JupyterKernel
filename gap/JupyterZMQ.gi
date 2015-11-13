#
# JupyterZMQ: Jupyter kernel using ZeroMQ
#
# Implementations
#

#XXX Move to library
Intersperse := function(lst, e)
    local x, res;
    if Length(lst) = 0 then
        res := [];
    else
        res := [lst[1]];
        for x in lst{[2..Length(lst)]} do
            Add(res, e);
            Add(res, x);
        od;
    fi;
    return res;
end;

hdlr := AtomicRecord(rec(

    kernel_info_request := function(kernel, msg)
        msg.header.msg_type := "kernel_info_reply";
        msg.content := rec( protocol_version := "5.0.0"
                        , implementation := "ihpcgap"
                        , implementation_version := "0.0.0"
                        , language_info := rec (
                                name := "HPC-GAP"
                                , version := "5.0.0"
                                , mimetype := "text/gap"
                                , file_extension := ".g"
                                , pygments_lexer := ""
                                , codemirror_mode := ""
                                , nbconvert_exporter := ""
                                )
                        , banner := Concatenation(
                                "HPC-GAP JupterZMQ kernel\n",
                                "Running on ", GAPInfo.BuildVersion, "\n",
                                "built on   ", GAPInfo.BuildDateTime, "\n" )
                        );
    end,

    history_request := function(kernel, msg)
        msg.header.msg_type := "history_reply";
        msg.content := rec( history := [] );
    end,

    execute_request := function(kernel, msg)
        local publ, res;

        if msg.content.code <> "" then
            res := String(READ_COMMAND(InputTextString(msg.content.code), false));
        else
            res := "";
        fi;

        kernel.execution_count := kernel.execution_count + 1;

        msg.header.msg_type := "execute_reply";
        msg.content := rec( status := "ok"
                            , execution_count := kernel.execution_count
                            , user_expressions := rec( res := "bla" )
                            );

        atomic kernel.iopub do
            Print("publishing...");
            publ := JupyterMsgReply(msg);
            publ.header.msg_type := "display_data";
            publ.content := rec( source := ""
                                 , data := rec( text\/plain := res
                                         , text\/html := "<b>HTML!</b>"
                                         )
                                 , metadata := rec() );

            ZmqSendMsg(kernel.iopub, publ);

            publ := JupyterMsgReply(msg);
            publ.header.msg_type := "status";
            publ.content := rec( execution_state := "idle" );
            ZmqSendMsg(kernel.iopub, publ);
        od;
    end,

    inspect_request := function(kernel, msg)
        msg.header.msg_type := "inspect_reply";
        msg.content := rec( status := "ok"
                            , found := false
                            , data := rec()
                            , metadata := rec()
                            );
    end,

    is_complete_request := function(kernel, msg)
        msg.header.msg_type := "is_complete_reply";
        msg.content := rec( status := "complete" );
    end,

    shutdown_request := function(kernel, msg)
        msg.header.msg_type := "shutdown_reply";
        msg.content := rec( restart := false );
    end
));

handle_shell_msg := function(kernel, msg)
    local hdl_dict, f, t, reply;
    
    reply := rec();
    reply.uuid := msg.uuid;
    reply.sep := msg.sep;
    reply.hmac := "";
    reply.parent_header := msg.header;
    reply.header := StructuralCopy(msg.header);
    reply.metadata := msg.metadata;
    reply.header.uuid := StringUUID(RandomUUID());
    reply.content := msg.content;

    t := msg.header.msg_type;

    if IsBound(hdlr.(t)) then
        hdlr.(t)(kernel, reply);
        return reply;
    else
        Print("unhandled message type: ", msg.header.msg_type, "\n");
        return fail;
    fi;
end;

shell_thread := function(kernel, sock)
    local msg, raw, zmq, res, i;

    zmq := ZmqRouterSocket(sock, kernel.uuid);
    while true do
        msg := ZmqRecvMsg(zmq);
        Print("received msg: ", msg.header.msg_type,
              " id: ", msg.header.msg_id,
              " length: ", Length(msg.remainder),
              "\n");

        res := handle_shell_msg(kernel, msg);
        if res = fail then
            Print("failed to handle message\n");
        else
            ZmqSendMsg(zmq, res);
        fi;

    od;
end;

control_thread := function(kernel, sock)
    local msg, zmq;

    zmq := ZmqRouterSocket(sock);
    while true do
        msg := ZmqReceive(zmq);
        Print("jupyter control:\n", msg, "\n");
    od;
end;

InstallGlobalFunction( JupyterKernelStart,
    function(conf)
        local address, kernel;

        address := Concatenation(conf.transport, "://", conf.ip, ":");

        kernel := AtomicRecord( rec( config := `conf
                                , uuid   := `String(RandomUUID())));

        kernel.iopub   := ShareObj(ZmqPublisherSocket(`Concatenation(address, String(conf.iopub_port))));
        kernel.control := CreateThread(control_thread, kernel, `Concatenation(address, String(conf.control_port)));
        kernel.shell   := CreateThread(shell_thread, kernel, `Concatenation(address, String(conf.shell_port)));
        kernel.stdin   := ShareObj(ZmqRouterSocket(`Concatenation(address, String(conf.stdin_port))));
        kernel.hb      := CreateThread(JupyterHBThreadFunc, kernel);

        kernel.execution_count := 0;

        return kernel;
    end);
