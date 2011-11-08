! Copyright (C) 2004, 2008 Slava Pestov.
! See http://factorcode.org/license.txt for BSD license.
USING: alien alien.c-types alien.data alien.syntax generic
assocs kernel kernel.private math io.ports sequences strings
sbufs threads unix unix.ffi unix.stat vectors io.buffers io.backend
io.encodings math.parser continuations system libc namespaces
make io.timeouts io.encodings.utf8 destructors
destructors.private accessors summary combinators locals
unix.time unix.types fry io.backend.unix.multiplexers
classes.struct init ;
QUALIFIED: io
IN: io.backend.unix

GENERIC: handle-fd ( handle -- fd )

TUPLE: fd < disposable fd ;

: init-fd ( fd -- fd )
    [
        |dispose
        dup fd>> F_SETFL O_NONBLOCK [ fcntl ] unix-system-call drop
        dup fd>> F_SETFD FD_CLOEXEC [ fcntl ] unix-system-call drop
    ] with-destructors ;

: <fd> ( n -- fd )
    fd new-disposable swap >>fd ;

M: fd dispose
    [
        {
            [ cancel-operation ]
            [ t >>disposed drop ]
            [ unregister-disposable ]
            [ fd>> close-file ]
        } cleave
    ] unless-disposed ;

M: fd handle-fd dup check-disposed fd>> ;

M: fd cancel-operation ( fd -- )
    [
        fd>>
        mx get-global
        [ remove-input-callbacks [ t swap resume-with ] each ]
        [ remove-output-callbacks [ t swap resume-with ] each ]
        2bi
    ] unless-disposed ;

M: unix tell-handle ( handle -- n )
    fd>> 0 SEEK_CUR [ lseek ] unix-system-call [ io-error ] [ ] bi ;

M: unix seek-handle ( n seek-type handle -- )
    swap {
        { io:seek-absolute [ SEEK_SET ] }
        { io:seek-relative [ SEEK_CUR ] }
        { io:seek-end [ SEEK_END ] }
        [ io:bad-seek-type ]
    } case
    [ fd>> swap ] dip [ lseek ] unix-system-call drop ;

M: unix can-seek-handle? ( handle -- ? )
    fd>> SEEK_CUR 0 lseek -1 = not ;

M: unix handle-length ( handle -- n/f )
    fd>> \ stat <struct> [ fstat -1 = not ] keep
    swap [ st_size>> ] [ drop f ] if ;

SYMBOL: +retry+ ! just try the operation again without blocking
SYMBOL: +input+
SYMBOL: +output+

ERROR: io-timeout ;

M: io-timeout summary drop "I/O operation timed out" ;

: wait-for-fd ( handle event -- )
    dup +retry+ eq? [ 2drop ] [
        [ [ self ] dip handle-fd mx get-global ] dip {
            { +input+ [ add-input-callback ] }
            { +output+ [ add-output-callback ] }
        } case
        "I/O" suspend [ io-timeout ] when
    ] if ;

: wait-for-port ( port event -- )
    '[ handle>> _ wait-for-fd ] with-timeout ;

! Some general stuff
CONSTANT: file-mode OCT: 0666
 
! Readers
: (refill) ( port -- n )
    [ handle>> ]
    [ buffer>> buffer-end ]
    [ buffer>> buffer-capacity ] tri read ;

! Returns an event to wait for which will ensure completion of
! this request
GENERIC: refill ( port handle -- event/f )

M: fd refill
    fd>> over buffer>> [ buffer-end ] [ buffer-capacity ] bi read
    {
        { [ dup 0 >= ] [ swap buffer>> n>buffer f ] }
        { [ errno EINTR = ] [ 2drop +retry+ ] }
        { [ errno EAGAIN = ] [ 2drop +input+ ] }
        [ (io-error) ]
    } cond ;

M: unix (wait-to-read) ( port -- )
    dup
    dup handle>> dup check-disposed refill dup
    [ dupd wait-for-port (wait-to-read) ] [ 2drop ] if ;

! Writers
GENERIC: drain ( port handle -- event/f )

M: fd drain
    fd>> over buffer>> [ buffer@ ] [ buffer-length ] bi write
    {
        { [ dup 0 >= ] [
            over buffer>> buffer-consume
            buffer>> buffer-empty? f +output+ ?
        ] }
        { [ errno EINTR = ] [ 2drop +retry+ ] }
        { [ errno EAGAIN = ] [ 2drop +output+ ] }
        [ (io-error) ]
    } cond ;

M: unix (wait-to-write) ( port -- )
    dup
    dup handle>> dup check-disposed drain
    dup [ wait-for-port ] [ 2drop ] if ;

M: unix io-multiplex ( ms/f -- )
    mx get-global wait-for-events ;

! On Unix, you're not supposed to set stdin to non-blocking
! because the fd might be shared with another process (either
! parent or child). So what we do is have the VM start a thread
! which pumps data from the real stdin to a pipe. We set the
! pipe to non-blocking, and read from it instead of the real
! stdin. Very crufty, but it will suffice until we get native
! threading support at the language level.
TUPLE: stdin < disposable control size data ;

M: stdin dispose*
    [
        [ control>> &dispose drop ]
        [ size>> &dispose drop ]
        [ data>> &dispose drop ]
        tri
    ] with-destructors ;

: wait-for-stdin ( stdin -- size )
    [ control>> CHAR: X over io:stream-write1 io:stream-flush ]
    [ size>> ssize_t heap-size swap io:stream-read ssize_t deref ]
    bi ;

:: refill-stdin ( buffer stdin size -- )
    stdin data>> handle-fd buffer buffer-end size read
    dup 0 < [
        drop
        errno EINTR = [ buffer stdin size refill-stdin ] [ (io-error) ] if
    ] [
        size = [ "Error reading stdin pipe" throw ] unless
        size buffer n>buffer
    ] if ;

M: stdin refill
    '[
        buffer>> _ dup wait-for-stdin refill-stdin f
    ] with-timeout ;

M: stdin cancel-operation
    [ size>> ] [ control>> ] bi [ cancel-operation ] bi@ ;

: control-write-fd ( -- fd ) &: control_write uint deref ;

: size-read-fd ( -- fd ) &: size_read uint deref ;

: data-read-fd ( -- fd ) &: stdin_read uint deref ;

: <stdin> ( -- stdin )
    stdin new-disposable
        control-write-fd <fd> <output-port> >>control
        size-read-fd <fd> init-fd <input-port> >>size
        data-read-fd <fd> >>data ;

SYMBOL: dispatch-signal-hook

dispatch-signal-hook [ [ drop ] ] initialize

: signal-pipe-fd ( -- n )
    OBJ-SIGNAL-PIPE special-object ; inline

: signal-pipe-loop ( port -- )
    '[
        int heap-size _ io:stream-read
        dup [ int deref dispatch-signal-hook get call( x -- ) ] when*
    ] loop ;

: start-signal-pipe-thread ( -- )
    signal-pipe-fd [
        <fd> init-fd <input-port>
        '[ _ signal-pipe-loop ] "Signals" spawn drop
    ] when* ;

M: unix init-stdio
    <stdin> <input-port>
    1 <fd> <output-port>
    2 <fd> <output-port>
    set-stdio ;

! mx io-task for embedding an fd-based mx inside another mx
TUPLE: mx-port < port mx ;

: <mx-port> ( mx -- port )
    dup fd>> mx-port <port> swap >>mx ;

: multiplexer-error ( n -- n )
    dup 0 < [
        errno [ EAGAIN = ] [ EINTR = ] bi or
        [ drop 0 ] [ (io-error) ] if
    ] when ;

:: ?flag ( n mask symbol -- n )
    n mask bitand 0 > [ symbol , ] when n ;

[ start-signal-pipe-thread ] "io.backend.unix:signal-pipe-thread" add-startup-hook
