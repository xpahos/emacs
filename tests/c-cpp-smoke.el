;;; c-cpp-smoke.el --- Read compile_commands.json without running a build -*- lexical-binding: t; -*-
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(let* ((root (file-name-as-directory (make-temp-file "emacs-clangd-" t)))
       (bin (expand-file-name "bin" root))
       (includes (expand-file-name "config/include" root))
       (header (expand-file-name "fixture.h" includes))
       (marker (expand-file-name "build-was-run" root))
       (files (mapcar (lambda (name) (expand-file-name name root)) '("main.c" "main.cpp")))
       (process-environment (copy-sequence process-environment))
       (exec-path (cons bin exec-path))
       (eglot-connect-timeout 15)
       (project--list nil))
  (unwind-protect
      (progn
        (make-directory bin t)
        (make-directory includes t)
        (dolist (command '("cmake" "make" "ninja" "clang" "clang++" "cc" "c++"))
          (let ((path (expand-file-name command bin)))
            (with-temp-file path
              (insert "#!/bin/sh\nprintf '%s\\n' \"$0\" >> "
                      (shell-quote-argument marker) "\nexit 99\n"))
            (set-file-modes path #o755)))
        (setenv "PATH" (concat bin path-separator (getenv "PATH")))
        (with-temp-file header (insert "static inline int fixture_answer(void) { return 42; }\n"))
        (dolist (file files)
          (with-temp-file file
            (insert "#ifdef FROM_DATABASE\n#include \"fixture.h\"\n"
                    "int main(void) { return fixture_answer(); }\n"
                    "#else\n#error compile_commands.json was not read\n#endif\n")))
        (with-temp-file (expand-file-name "compile_commands.json" root)
          (insert (json-serialize
                   (vconcat
                    (mapcar
                     (lambda (file)
                       (list :directory root :file file
                             :arguments (vector (if (string-suffix-p ".cpp" file) "clang++" "clang")
                                                "-DFROM_DATABASE=1" "-I" includes "-c" file)))
                     files)))))
        (my-project-open root)
        (dolist (file files)
          (find-file file)
          (cl-assert (null eglot-sync-connect))
          (run-hooks 'post-command-hook)
          (let ((deadline (+ (float-time) 15)))
            (while (and (not (eglot-managed-p)) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (cl-assert (eglot-current-server))
          (goto-char 1) (search-forward "fixture_answer") (backward-char 3)
          (let ((deadline (+ (float-time) 15)) definitions)
            (while (and (not definitions) (< (float-time) deadline))
              (setq definitions
                    (xref-backend-definitions 'eglot (xref-backend-identifier-at-point 'eglot)))
              (unless definitions (accept-process-output nil 0.1)))
            (cl-assert definitions)
            (cl-assert (equal (file-truename
                              (xref-file-location-file (xref-item-location (car definitions))))
                             (file-truename header))))
          (cl-assert (not (file-exists-p marker))))
        (princ "C and C++ read compile_commands.json: include path and macro resolved; no build command ran.\n"))
    (dolist (file files)
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer
          (when-let* ((server (eglot-current-server))) (eglot-shutdown server)))
        (kill-buffer buffer)))
    (delete-directory root t)))
