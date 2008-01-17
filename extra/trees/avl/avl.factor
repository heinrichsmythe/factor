! Copyright (C) 2007 Alex Chapman
! See http://factorcode.org/license.txt for BSD license.
USING: combinators kernel generic math math.functions math.parser
namespaces io prettyprint.backend sequences trees assocs parser ;
IN: trees.avl

TUPLE: avl ;

INSTANCE: avl tree-mixin

: <avl> ( -- tree )
    avl construct-tree ;

TUPLE: avl-node balance ;

: <avl-node> ( key value -- node )
    swap <node> 0 avl-node construct-boa tuck set-delegate ;

: change-balance ( node amount -- )
    over avl-node-balance + swap set-avl-node-balance ;

: rotate ( node -- node )
    dup node+link dup node-link pick set-node+link tuck set-node-link ;    

: single-rotate ( node -- node )
    0 over set-avl-node-balance 0 over node+link set-avl-node-balance rotate ;

: pick-balances ( a node -- balance balance )
    avl-node-balance {
        { [ dup zero? ] [ 2drop 0 0 ] }
        { [ over = ] [ neg 0 ] }
        { [ t ] [ 0 swap ] }
    } cond ;

: double-rotate ( node -- node )
    [
        node+link [
            node-link current-side get neg over pick-balances rot 0 swap set-avl-node-balance
        ] keep set-avl-node-balance
    ] keep tuck set-avl-node-balance
    dup node+link [ rotate ] with-other-side over set-node+link rotate ;

: select-rotate ( node -- node )
    dup node+link avl-node-balance current-side get = [ double-rotate ] [ single-rotate ] if ;

: balance-insert ( node -- node taller? )
    dup avl-node-balance {
        { [ dup zero? ] [ drop f ] }
        { [ dup abs 2 = ] [ sgn neg [ select-rotate ] with-side f ] }
        { [ drop t ] [ t ] } ! balance is -1 or 1, tree is taller
    } cond ;

DEFER: avl-set

: avl-insert ( value key node -- node taller? )
    2dup node-key key< left right ? [
        [ node-link avl-set ] keep swap
        >r tuck set-node-link r>
        [ dup current-side get change-balance balance-insert ] [ f ] if
    ] with-side ;

: (avl-set) ( value key node -- node taller? )
    2dup node-key key= [
        -rot pick set-node-key over set-node-value f
    ] [ avl-insert ] if ;

: avl-set ( value key node -- node taller? )
    [ (avl-set) ] [ <avl-node> t ] if* ;

M: avl set-at ( value key node -- node )
    [ avl-set drop ] change-root ;

: delete-select-rotate ( node -- node shorter? )
    dup node+link avl-node-balance zero? [
        current-side get neg over set-avl-node-balance
        current-side get over node+link set-avl-node-balance rotate f
    ] [
        select-rotate t
    ] if ;

: rebalance-delete ( node -- node shorter? )
    dup avl-node-balance {
        { [ dup zero? ] [ drop t ] }
        { [ dup abs 2 = ] [ sgn neg [ delete-select-rotate ] with-side ] }
        { [ drop t ] [ f ] } ! balance is -1 or 1, tree is not shorter
    } cond ;

: balance-delete ( node -- node shorter? )
    current-side get over avl-node-balance {
        { [ dup zero? ] [ drop neg over set-avl-node-balance f ] }
        { [ dupd = ] [ drop 0 over set-avl-node-balance t ] }
        { [ t ] [ dupd neg change-balance rebalance-delete ] }
    } cond ;

: avl-replace-with-extremity ( to-replace node -- node shorter? )
    dup node-link [
        swapd avl-replace-with-extremity >r over set-node-link r>
        [ balance-delete ] [ f ] if
    ] [
        tuck copy-node-contents node+link t
    ] if* ;

: replace-with-a-child ( node -- node shorter? )
    #! assumes that node is not a leaf, otherwise will recurse forever
    dup node-link [
        dupd [ avl-replace-with-extremity ] with-other-side
        >r over set-node-link r> [ balance-delete ] [ f ] if
    ] [
        [ replace-with-a-child ] with-other-side
    ] if* ;

: avl-delete-node ( node -- node shorter? )
    #! delete this node, returning its replacement, and whether this subtree is
    #! shorter as a result
    dup leaf? [
        drop f t
    ] [
        left [ replace-with-a-child ] with-side
    ] if ;

GENERIC: avl-delete ( key node -- node shorter? deleted? )

M: f avl-delete ( key f -- f f f ) nip f f ;

: (avl-delete) ( key node -- node shorter? deleted? )
    tuck node-link avl-delete >r >r over set-node-link r>
    [ balance-delete r> ] [ f r> ] if ;

M: avl-node avl-delete ( key node -- node shorter? deleted? )
    2dup node-key key-side dup zero? [
        drop nip avl-delete-node t
    ] [
        [ (avl-delete) ] with-side
    ] if ;

M: avl delete-at ( key node -- )
    [ avl-delete 2drop ] change-root ;

M: avl new-assoc 2drop <avl> ;

: >avl ( assoc -- avl )
    T{ avl T{ tree f f 0 } } assoc-clone-like ;

M: avl assoc-like
    drop dup avl? [ >avl ] unless ;

: AVL{
    \ } [ >avl ] parse-literal ; parsing

M: avl pprint-delims drop \ AVL{ \ } ;
