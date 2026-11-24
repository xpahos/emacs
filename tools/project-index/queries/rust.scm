; Rust items.  `impl' blocks give methods their type as scope without being results.
(mod_item name: (identifier) @name) @definition.module
(struct_item name: (type_identifier) @name) @definition.struct
(enum_item name: (type_identifier) @name) @definition.enum
(union_item name: (type_identifier) @name) @definition.union
(trait_item name: (type_identifier) @name) @definition.trait
(type_item name: (type_identifier) @name) @definition.alias
(enum_variant name: (identifier) @name) @definition.member
(field_declaration name: (field_identifier) @name) @definition.field
(const_item name: (identifier) @name) @definition.constant
(static_item name: (identifier) @name) @definition.variable
(macro_definition name: (identifier) @name) @definition.macro
(impl_item type: [(type_identifier) @name (generic_type type: (type_identifier) @name)]) @definition._scope
(source_file (function_item name: (identifier) @name) @definition.function)
(mod_item body: (declaration_list (function_item name: (identifier) @name) @definition.function))
(impl_item body: (declaration_list (function_item name: (identifier) @name) @definition.method))
(trait_item body: (declaration_list [(function_item name: (identifier) @name) (function_signature_item name: (identifier) @name)] @definition.method))
