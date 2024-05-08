# Refactoring


## Concurrency
Use build-in tools for concurrency, like the modules:

Process
Task
Agent
GenServer
Supervisor
DynamicSupervisor
Registry

## Behaviours, protocols and the use macro
Find the best way to apply Elixir tools for polymorphics - behaviour vs. protocol
Find the best way to organize the rsmp library.

## RSMP concepts
Structure around the rsmp4 concept of sxl modules.
Unifiy site and supervisor into a generic rsmp node.


## Service routing
How do we map topic paths to services handling them?

Each pair of {service,component} maps to a service.

af34/state 							-> dispatcher
f32a/command/tlc/2/tc 	-> tc
422e/status/tlc/1/tc		-> tc

## Retain
Status messages and alarms should probably be retained, so that when a receiver reconnects, it get's the latest status.
This implies that these messages should include the component in the topic, so that a value for each component can be retained.

But commands and responses should probably not be retained. So we could choose to include the component be  in the payload, rather than the topic. We could then use the format we want, e.g. a single component, a list of components, etc. This is more similar to a regular web api.


## Business Logic
Node: An RSMP node, can have services that run locally
Remote: A reference to a remote node

Service: runs a service, receives commands from a remote handler, sends the handler results and status
Handler: A reference to a service runnining on a remote node, sends commands to a remote service, receives results and status from the remote service

Converter: converts service data between internal representation and rsmp sxl format

## Supervision tree
Application
	Registry	
	NodesSupervisor (to do)
		[Node]  (supervisor)
			Connection
				emqtt
			[Services]
			RemotesSupervisor (dynamic supervisor)
				[Remotes]


RSMP.Node.TLC is not a process, it just starts a Node with the relevant services.
RSMP.Service.TLC uses RSMP.Service, which makes it a GenServer process.


## Sending data
A service is process with temporal aspects, and it has some state (data).
Sometimes it needs to send out a status, e.g. when it receives a command to change, it will then send a status message reflecting the new state.

There's a conversion between the internal state and the sxl format, which is handled by the associated converter.

The actual mqtt delivery is handled by the emqtt lib, which is used by the Connection module. So the overall flow is:

	service -> connection -> emqtt

We want a general way to send out a status message for some module/code.

	send_status(service,code)

This function should fetch the data form the service, convert it and have deliver it via the connection

