; Kotlin top-level and member declarations.  Function bodies are never descended into.
(package_header (qualified_identifier) @name) @definition.package
(class_declaration name: (identifier) @name) @definition.class
(object_declaration name: (identifier) @name) @definition.object
(companion_object name: (identifier) @name) @definition.object
(type_alias type: (identifier) @name) @definition.alias
(enum_entry (identifier) @name) @definition.member
(source_file (function_declaration name: (identifier) @name) @definition.function)
(class_body (function_declaration name: (identifier) @name) @definition.method)
(source_file (property_declaration (variable_declaration (identifier) @name)) @definition.variable)
(class_body (property_declaration (variable_declaration (identifier) @name)) @definition.property)
(class_parameter ["val" "var"] (identifier) @name) @definition.property
