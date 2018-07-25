# RabbitMQ (Message) Tracing Plugin

This is an opinionated tracing plugin that extends RabbitMQ management UI.
It logs messages passing through vhosts [with enabled tracing](http://www.rabbitmq.com/firehose.html) to a log
file.

## Usage

This plugin ships with RabbitMQ. Enabled it with `rabbitmq-plugins enable`,
then see a "Tracing" tab in the management UI.


## Configuration

Configuration options are under the `rabbitmq_tracing` app (config section,
if you will):

 * `directory`: controls where the log files go. It defaults to "/var/tmp/rabbitmq-tracing".
 * `username`: username to be used by tracing event consumers (default: `<<"guest">>`)
 * `password`: password to be used by tracing event consumers (default: `<<"guest">>`)

## Performance

TL;DR: this plugin is intended to be used in development and QA environments.
It will increase RAM consumption and CPU usage of a node.

On a few year old developer-grade machine, rabbitmq-tracing can write
about 2000 msg/s to a log file. You should be careful using
rabbitmq-tracing if you think you're going to capture more messages
than this. Any messages that can't be logged are queued.

The code to serve up the log files over HTTP is not at all
sophisticated or efficient, it loads the whole log into memory. If you
have large log files you may wish to transfer them off the server in
some other way.

## HTTP API

```
GET            /api/traces
GET            /api/traces/<vhost>
GET PUT DELETE /api/traces/<vhost>/<name>
GET            /api/trace-files
GET     DELETE /api/trace-files/<name>    (GET returns the file as text/plain)
```

Example for how to create a trace using [RabbitMQ HTTP API](http://www.rabbitmq.com/management.html):

```
curl -i -u guest:guest -H "content-type:application/json" -XPUT \
     http://localhost:55672/api/traces/%2f/my-trace \
     -d'{"format":"text","pattern":"#", "max_payload_bytes":1000}'
```

`max_payload_bytes` is optional (omit it to prevent payload truncation),
format and pattern are mandatory.
