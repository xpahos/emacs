; Top-level Go declarations.  Locals live in blocks, which no pattern reaches.
(source_file (package_clause (package_identifier) @name) @definition.package)
(source_file (function_declaration name: (identifier) @name) @definition.function)
(source_file (method_declaration
  receiver: (parameter_list (parameter_declaration
    type: [(type_identifier) @scope
           (pointer_type (type_identifier) @scope)
           (generic_type type: (type_identifier) @scope)
           (pointer_type (generic_type type: (type_identifier) @scope))]))
  name: (field_identifier) @name) @definition.method)
(source_file (type_declaration (type_spec name: (type_identifier) @name type: (interface_type)) @definition.interface))
(source_file (type_declaration (type_spec name: (type_identifier) @name type: (struct_type)) @definition.struct))
(source_file (type_declaration (type_spec name: (type_identifier) @name) @definition.type))
(source_file (type_declaration (type_alias name: (type_identifier) @name) @definition.alias))
(struct_type (field_declaration_list (field_declaration name: (field_identifier) @name) @definition.field))
(interface_type (method_elem name: (field_identifier) @name) @definition.method)
(source_file (const_declaration (const_spec name: (identifier) @name) @definition.constant))
(source_file (var_declaration (var_spec name: (identifier) @name) @definition.variable))
