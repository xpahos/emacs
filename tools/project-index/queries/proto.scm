; Protocol Buffers definitions.  Fields keep their message as the scope.
(package (full_ident) @name) @definition.package
(message (message_name (identifier) @name)) @definition.message
(enum (enum_name (identifier) @name)) @definition.enum
(enum_field (identifier) @name) @definition.member
(service (service_name (identifier) @name)) @definition.service
(rpc (rpc_name (identifier) @name)) @definition.rpc
(field (identifier) @name) @definition.field
(map_field (identifier) @name) @definition.field
(oneof_field (identifier) @name) @definition.field
(oneof (identifier) @name) @definition.field
