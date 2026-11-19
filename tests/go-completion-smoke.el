;;; go-completion-smoke.el --- Asynchronous completion against real gopls -*- lexical-binding: t; -*-
;; Batch: no popup frame; drives the CAPF table and exit function as Corfu does.
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(load (expand-file-name "go-completion.el" my-test-config-dir) nil t)
;; Emacs 31 reports popup support in batch (tty child frames); there is no frame to draw.
(advice-add 'corfu--popup-support-p :override #'ignore)

(defun my-go-smoke-wait (what predicate)
  (let ((deadline (+ (float-time) 30)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (or (funcall predicate) (error "Timed out waiting for %s" what))))

(defun my-go-smoke-candidates (prefix)
  "Type PREFIX at point and return the fresh candidates without blocking."
  (insert prefix)
  (let* ((start (float-time))
         (capf (my-go-completion-at-point))
         (query (buffer-substring-no-properties (car capf) (point))))
    (my-go--table query nil t)
    (cl-assert (< (- (float-time) start) 0.05) nil "CAPF blocked")
    (my-go-smoke-wait prefix (lambda () (and my-go--latest (my-go--fresh-p my-go--latest)
                                             (eql (car capf) (my-go--reply-beg my-go--latest)))))
    (mapcar #'substring-no-properties (my-go--table query nil t))))

(defun my-go-smoke-accept (candidate)
  "Accept CANDIDATE as Corfu's Enter does."
  (let* ((capf (my-go-completion-at-point))
         (proxy (car (member candidate (my-go--table (buffer-substring-no-properties
                                                      (car capf) (point))
                                                     nil t)))))
    (cl-assert proxy nil "%s not offered" candidate)
    (completion--replace (car capf) (point) proxy)
    (my-go--exit proxy 'finished)))

(defun my-go-smoke-clear ()
  (delete-region (line-beginning-position) (line-end-position))
  (insert "\t"))

(let* ((root (file-name-as-directory (file-truename (make-temp-file "emacs-go-completion-" t))))
       (file (expand-file-name "main.go" root))
       (eglot-connect-timeout 30)
       (project--list nil))
  (unwind-protect
      (progn
        (make-directory (expand-file-name "lib" root))
        (with-temp-file (expand-file-name "go.mod" root)
          (insert "module example.test/demo\n\ngo 1.24\n"))
        (with-temp-file (expand-file-name "lib/lib.go" root)
          (insert "package lib\n\nvar Value = 1\n\nfunc Exported() int { return Value }\n"))
        (with-temp-file file
          (insert "package demo\n\nimport \"example.test/demo/lib\"\n\n"
                  "const Answer = 42\n\nvar Global = lib.Value\n\n"
                  "type Thing struct{ Field int }\n\nfunc (Thing) Method() {}\n\n"
                  "func Probe() {\n\tlocal := 1\n\tobj := Thing{}\n\t_, _ = local, obj\n\t\n}\n"))
        (my-project-open root)
        (find-file file)
        (switch-to-buffer (current-buffer))
        (run-hooks 'post-command-hook)
        (my-go-smoke-wait "Eglot" #'eglot-managed-p)
        (cl-assert (memq #'my-go-completion-at-point completion-at-point-functions))
        (cl-assert (not (memq #'eglot-completion-at-point completion-at-point-functions)))
        (cl-assert (and corfu-mode corfu-auto))
        (cl-assert my-go--warmed)
        ;; The budget reached gopls in initialize.
        (cl-assert (with-current-buffer (jsonrpc-events-buffer (eglot-current-server))
                     (goto-char (point-min))
                     (search-forward "\"completionBudget\":\"20ms\"" nil t)))
        (goto-char (point-min))
        (search-forward "_, _ = local, obj\n\t")
        (pcase-dolist (`(,prefix . ,expected)
                       '(("Ans" "Answer") ("Glo" "Global") ("loc" "local") ("Thi" "Thing")
                         ("Pro" "Probe") ("obj." "Field" "Method") ("lib." "Exported" "Value")))
          (let ((cands (my-go-smoke-candidates prefix)))
            (dolist (name expected)
              (cl-assert (member name cands) nil "%s missing after %s: %S" name prefix cands)))
          (my-go-smoke-clear))
        ;; Cached reply, more typing, then accept: edits apply to the request snapshot.
        (my-go-smoke-candidates "obj.Me")
        (insert "th")
        (my-go-smoke-accept "Method")
        (cl-assert (looking-back "\tobj\\.Method" (line-beginning-position)))
        (my-go-smoke-clear)
        ;; Unimported package: gopls adds the import as an additional edit.
        (my-go-smoke-candidates "strings.ToUpp")
        (my-go-smoke-accept "ToUpper")
        (cl-assert (looking-back "\tstrings\\.ToUpper" (line-beginning-position)))
        (cl-assert (save-excursion (goto-char (point-min)) (search-forward "\"strings\"" nil t)))
        (kill-buffer)
        (princ "Real gopls: async suggestions for constants, globals, locals, types, functions,\n")
        (princ "fields, methods and package members; snapshot insertion and import edit applied.\n"))
    (when-let* ((buffer (get-file-buffer file)))
      (with-current-buffer buffer
        (when-let* ((server (eglot-current-server))) (eglot-shutdown server)))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))
    (delete-directory root t)))
