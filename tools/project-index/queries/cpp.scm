; Namespace- and class-scope C++ declarations.  Out-of-line member definitions
; (Shape::area) keep their qualifier as the scope.
(namespace_definition name: (namespace_identifier) @name) @definition.namespace
(class_specifier name: (type_identifier) @name body: (_)) @definition.class
(struct_specifier name: (type_identifier) @name body: (_)) @definition.struct
(union_specifier name: (type_identifier) @name body: (_)) @definition.union
(enum_specifier name: (type_identifier) @name body: (_)) @definition.enum
(enumerator name: (identifier) @name) @definition.member
(type_definition declarator: (type_identifier) @name) @definition.type
(alias_declaration name: (type_identifier) @name) @definition.alias
(preproc_def name: (identifier) @name) @definition.macro
(preproc_function_def name: (identifier) @name) @definition.macro
(field_declaration_list (field_declaration declarator: (field_identifier) @name) @definition.field)
(field_declaration_list (field_declaration declarator: (function_declarator declarator: (field_identifier) @name)) @definition.method)
(field_declaration_list (declaration declarator: (function_declarator declarator: (identifier) @name)) @definition.constructor)
(field_declaration_list (function_definition declarator: (function_declarator declarator: (field_identifier) @name)) @definition.method)
(function_definition declarator: (function_declarator declarator: (qualified_identifier scope: (namespace_identifier) @scope name: (identifier) @name))) @definition.method
(translation_unit (function_definition declarator: (function_declarator declarator: (identifier) @name)) @definition.function)
(declaration_list (function_definition declarator: (function_declarator declarator: (identifier) @name)) @definition.function)
(translation_unit (declaration declarator: (function_declarator declarator: (identifier) @name)) @definition.function)
(declaration_list (declaration declarator: (function_declarator declarator: (identifier) @name)) @definition.function)
(template_declaration (function_definition declarator: (function_declarator declarator: (identifier) @name)) @definition.function)
(translation_unit (declaration declarator: (init_declarator declarator: (identifier) @name)) @definition.variable)
(declaration_list (declaration declarator: (init_declarator declarator: (identifier) @name)) @definition.variable)
