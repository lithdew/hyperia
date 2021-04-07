# hyperia

A playground of Zig async code.

The intent is to work towards eventually upstreaming the majority of the code in this playground to the Zig standard library (i.e. async sockets, timers, event loops, lockless/lock-free synchronization primitives).

All other code present in this playground comprises of utilities that are intended to make writing correct high-performance async Zig applications simpler (i.e. lock-free thread-safe object pool, thread-safe memory allocator that suspends until all allocations are freed, etc.).

All code is heavily a work-in-progress - a lot of work is being put into 1) writing a thorough unit test suite to check for correctness, and 2) ensuring that a flexible-enough API surface is provided by introducing a slew of thorough async code examples.

The code in this playground only supports Linux for the time being, though work will eventually be done to support Mac and Windows as well.

If you would like to partake contributing to the playground to make Zig's async/await story production-ready enough for creating high-performance HTTP/TCP/UDP/WebSocket clients and servers a reality sooner, please do reach out to me (lithdew#6092) on the Zig Programming Language Discord :).

## [TCP Client Example](example_tcp_client.zig)

An example that demonstrates what it takes to make a production-ready TCP client.

The TCP client points to a single destination address (by default 127.0.0.1:9000), and comprises of a bounded pool of connections (bounded by default to a maximum of 4 connections; configurable).

Pooling is performed in order to reduce the likelihood of TCP head-of-line blocking, which significantly hampers message throughput in the case of packet loss.

Messages to be written to the client's destination are queued into a multiple-producer/multiple-consumer queue. Connections in the pool pop messages from the queue and directly send the messages to the client's destination.

Connections are spun up and registered to the pool dynamically. When a message is queued to be written, if the pool still has capacity for spawning another connection and the client's write queue appears to still contain messages that have yet to be written, a new connection is spun up and registered.

The TCP client additionally supports auto-reconnection that complements the pooling strategy outlined above. If all connections in the pool spontaneously close, the last connection that was closed attempts to reconnect back to the clients destination up to a configurable number of times. If all reconnection attempts fail, all pending attempts to queue messages to the client to be written to the clients' destination are cancelled.

Work still needs to be done to implement async timers to timeout socket reads/writes/connect attempts that take too long.

Work additionally needs to be done in order to thoroughly audit the correctness of the TCP client's state machine.