; Python module- and class-level definitions; function bodies are not descended into.
(class_definition name: (identifier) @name) @definition.class
(module (function_definition name: (identifier) @name) @definition.function)
(module (decorated_definition definition: (function_definition name: (identifier) @name)) @definition.function)
(class_definition body: (block (function_definition name: (identifier) @name) @definition.method))
(class_definition body: (block (decorated_definition definition: (function_definition name: (identifier) @name)) @definition.method))
(module (expression_statement (assignment left: (identifier) @name)) @definition.variable)
(class_definition body: (block (expression_statement (assignment left: (identifier) @name)) @definition.field))
