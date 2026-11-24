; Java types and their members; locals sit in method bodies, which no pattern reaches.
(package_declaration (scoped_identifier) @name) @definition.package
(package_declaration (identifier) @name) @definition.package
(class_declaration name: (identifier) @name) @definition.class
(interface_declaration name: (identifier) @name) @definition.interface
(enum_declaration name: (identifier) @name) @definition.enum
(record_declaration name: (identifier) @name) @definition.class
(annotation_type_declaration name: (identifier) @name) @definition.interface
(enum_constant name: (identifier) @name) @definition.member
(method_declaration name: (identifier) @name) @definition.method
(constructor_declaration name: (identifier) @name) @definition.constructor
(class_body (field_declaration declarator: (variable_declarator name: (identifier) @name)) @definition.field)
(interface_body (constant_declaration declarator: (variable_declarator name: (identifier) @name)) @definition.constant)
