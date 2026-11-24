; File-scope C declarations: functions, prototypes, types, enumerators, globals, macros.
(translation_unit (function_definition declarator: (function_declarator declarator: (identifier) @name)) @definition.function)
(translation_unit (function_definition declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function)
(translation_unit (declaration declarator: (function_declarator declarator: (identifier) @name)) @definition.function)
(translation_unit (declaration declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function)
(translation_unit (declaration declarator: (identifier) @name) @definition.variable)
(translation_unit (declaration declarator: (init_declarator declarator: (identifier) @name)) @definition.variable)
(struct_specifier name: (type_identifier) @name body: (_)) @definition.struct
(union_specifier name: (type_identifier) @name body: (_)) @definition.union
(enum_specifier name: (type_identifier) @name body: (_)) @definition.enum
(enumerator name: (identifier) @name) @definition.member
(field_declaration_list (field_declaration declarator: (field_identifier) @name) @definition.field)
(type_definition declarator: (type_identifier) @name) @definition.type
(preproc_def name: (identifier) @name) @definition.macro
(preproc_function_def name: (identifier) @name) @definition.macro
