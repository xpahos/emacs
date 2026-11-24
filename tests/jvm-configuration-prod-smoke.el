;;; jvm-configuration-prod-smoke.el --- Kotlin LSP on a real configuration-prod copy -*- lexical-binding: t; -*-
;; EMACS_TEST_KOTLIN_ROOT names a configuration-prod checkout (see README "Java and Kotlin").
;; Only imports the Gradle model; runs no Gradle tasks of the project.
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(setq backtrace-on-error-noninteractive nil)

(defconst my-kotlin-smoke-root
  (let ((value (getenv "EMACS_TEST_KOTLIN_ROOT")))
    (unless (and value (file-exists-p (expand-file-name "config/ConfigurationRoot.kts" value)))
      (error "EMACS_TEST_KOTLIN_ROOT must name a configuration-prod checkout"))
    (file-name-as-directory (file-truename value))))

(defun my-kotlin-smoke-wait (what seconds fn)
  (let ((deadline (+ (float-time) seconds)) result last-error)
    (while (and (not result) (< (float-time) deadline))
      (condition-case err (setq result (funcall fn)) (error (setq last-error err)))
      (unless result (accept-process-output nil 1)))
    (or result (error "%s: none after %ss (%S)" what seconds last-error))))

(defun my-kotlin-smoke-visit (file)
  (find-file (expand-file-name file my-kotlin-smoke-root))
  (cl-assert (eq major-mode 'kotlin-mode) nil "%s is in %s" file major-mode)
  (run-hooks 'post-command-hook)
  (my-kotlin-smoke-wait (concat "Eglot for " file) 120 #'eglot-managed-p))

(defun my-kotlin-smoke-definition (file search seconds)
  "Definition file of the identifier ending SEARCH in FILE."
  (my-kotlin-smoke-visit file)
  (goto-char (point-min))
  (search-forward search)
  (backward-char 1)
  (my-kotlin-smoke-wait (concat "definition of " search) seconds
                        (lambda ()
                          (when-let* ((defs (xref-backend-definitions
                                             'eglot (xref-backend-identifier-at-point 'eglot))))
                            (xref-location-group (xref-item-location (car defs)))))))

(let ((eglot-connect-timeout 300) (project--list nil) (start (float-time)))
  (my-project-open my-kotlin-smoke-root)
  ;; The first request waits for the Gradle import and indexing.
  (let ((target (my-kotlin-smoke-definition "config/compute/applications/interconnect/values.kt"
                                            "= SaltRole(" 1800)))
    (cl-assert (equal (file-truename target)
                      (expand-file-name "config/common/iaas/config/k8s/SaltRole.kt" my-kotlin-smoke-root))
               nil "SaltRole resolved to %s" target)
    (princ (format "values.kt SaltRole -> %s (%.0fs incl. import)\n"
                   (file-relative-name target my-kotlin-smoke-root) (- (float-time) start))))
  ;; A dependency definition must open, not merely resolve to a jar: URI.
  (my-kotlin-smoke-visit "config/compute/applications/interconnect/application.kt")
  (goto-char (point-min))
  (search-forward "= Application")
  (backward-char 1)
  (let* ((source (current-buffer))
         (item (my-kotlin-smoke-wait "definition of Application" 120
                                     (lambda () (car (xref-backend-definitions
                                                      'eglot (xref-backend-identifier-at-point 'eglot))))))
         (marker (xref-location-marker (xref-item-location item))))
    (with-current-buffer (marker-buffer marker)
      (cl-assert buffer-read-only)
      (cl-assert (not buffer-file-name))
      (goto-char marker)
      (cl-assert (looking-at "Application\\_>") nil "At %S" (buffer-substring (point) (line-end-position)))
      (cl-assert (string-match-p "\\_<class Application\\_>"
                                 (buffer-substring (line-beginning-position) (line-end-position))))
      (princ (format "DSL dependency Application -> %s line %d: %s\n" (buffer-name) (line-number-at-pos)
                     (string-trim (buffer-substring (line-beginning-position) (line-end-position))))))
    (set-buffer source))
  ;; Typed on a new line of the real file, then removed; the file is never saved.
  (goto-char (point-max))
  (let ((start (point)))
    (insert "\nval probe = Application.DataSource.")
    (unwind-protect
        (let ((cands (my-kotlin-smoke-wait "DSL member completion" 120
                                           (lambda ()
                                             (pcase-let ((`(,beg ,end ,table . ,_) (my-jvm-completion-at-point)))
                                               (all-completions (buffer-substring-no-properties beg end) table))))))
          (cl-assert (and (member "LOAD_BALANCERS" cands) (member "SERVER_GROUPS" cands))
                     nil "DataSource candidates %S" (mapcar #'substring-no-properties cands))
          (princ (format "Application.DataSource. completion: %S\n" (mapcar #'substring-no-properties cands))))
      (delete-region start (point-max))
      (set-buffer-modified-p nil)))
  (cl-assert (not (buffer-modified-p)))
  ;; .kts scripts get semantic support separately from ordinary .kt sources.
  (let ((target (my-kotlin-smoke-definition "config/ConfigurationRoot.kts" "computeConfig" 120)))
    (cl-assert (equal (file-truename target)
                      (expand-file-name "config/compute/ComputeConfig.kt" my-kotlin-smoke-root))
               nil "computeConfig resolved to %s" target)
    (princ ".kts: ConfigurationRoot.kts computeConfig -> config/compute/ComputeConfig.kt\n"))
  (princ "configuration-prod: Gradle model imported; cross-file, dependency and completion verified.\n")
  (while (> (length (tab-bar-tabs)) 1) (tab-bar-close-tab (length (tab-bar-tabs)))))
