;;; jvm.el --- Java (JDT LS) and Kotlin (Kotlin LSP) through Eglot -*- lexical-binding: t; -*-

;; Versions, install locations and recovery are in README "Java and Kotlin".
;; kotlin-mode's autoloads map .kt and .kts; .java uses the built-in java-mode.

(require 'eglot)
(require 'corfu)
(require 'corfu-auto)

(defvar my-jvm-gradle-java-version 17
  "JDK major version for Gradle imports; Gradle 7.4.2 (configuration-prod) cannot run on 23.")
(defvar my-jvm-jdtls-java-home nil
  "Java 25+ home for JDT LS 1.63.0; nil uses the JetBrains Runtime bundled with kotlin-lsp.")

(defun my-jvm-java-major (home)
  "Major Java version of the JDK at HOME, from its release file, or nil."
  (let ((release (expand-file-name "release" home)))
    (when (file-readable-p release)
      (with-temp-buffer
        (insert-file-contents release)
        (when (re-search-forward "^JAVA_VERSION=\"\\([0-9]+\\)" nil t)
          (string-to-number (match-string 1)))))))

(defun my-jvm-java-home (major)
  "Home of the installed JDK of version MAJOR, or nil.
java_home answers an absent version with another JDK, so its answer is checked."
  (with-temp-buffer
    (when (eql 0 (ignore-errors
                   (call-process "/usr/libexec/java_home" nil t nil "-v" (number-to-string major))))
      (let ((home (string-trim (buffer-string))))
        (and (eql (my-jvm-java-major home) major) home)))))

(defun my-jvm-jdtls-java ()
  "Java 25+ executable for JDT LS, or nil."
  (when-let* ((home (or my-jvm-jdtls-java-home
                        (when-let* ((lsp (executable-find "kotlin-lsp")))
                          (expand-file-name "../jbr/Contents/Home"
                                            (file-name-directory (file-truename lsp))))))
              ((>= (or (my-jvm-java-major home) 0) 25)))
    (expand-file-name "bin/java" home)))

(defun my-jvm-state-directory (server root)
  "Private state of SERVER for project ROOT, one per canonical path.
Copies with the same directory name never share mutable server state."
  (expand-file-name (format "jvm-servers/%s/%s/" server
                            (secure-hash 'sha256 (file-name-as-directory (file-truename root))))
                    user-emacs-directory))

(defun my-jvm-kotlin-contact (_interactive project)
  "Kotlin LSP for PROJECT; its Gradle import runs on JDK 17 through JAVA_HOME."
  (list "env" (concat "JAVA_HOME=" (my-jvm-java-home my-jvm-gradle-java-version))
        "kotlin-lsp" "--stdio"
        (concat "--system-path=" (my-jvm-state-directory "kotlin" (project-root project)))
        ;; Otherwise the index lives in ~/Library/Caches, keyed by root path and
        ;; locked by whichever server opened it first.
        :initializationOptions
        (list :indexDir (expand-file-name "index" (my-jvm-state-directory "kotlin" (project-root project))))))

(defun my-jvm-jdtls-contact (_interactive project)
  "JDT LS for PROJECT, running on Java 25+ while Gradle imports use JDK 17."
  (list "jdtls" "--java-executable" (my-jvm-jdtls-java)
        "-data" (expand-file-name "data" (my-jvm-state-directory "jdtls" (project-root project)))
        ;; jdtls.py defaults this to the installation, shared by every running server.
        "-configuration"
        (expand-file-name "configuration" (my-jvm-state-directory "jdtls" (project-root project)))
        :initializationOptions
        `(:settings (:java (:import (:gradle (:java (:home ,(my-jvm-java-home my-jvm-gradle-java-version)))))))))

(defun my-jvm-missing ()
  "Describe what the current buffer's server lacks, or nil when it can start."
  (let* ((kotlin (derived-mode-p 'kotlin-mode 'kotlin-ts-mode))
         (program (if kotlin "kotlin-lsp" "jdtls")))
    (cond ((not (executable-find program))
           (format "%s not found on exec-path; install it as in README \"Java and Kotlin\"" program))
          ((not (my-jvm-java-home my-jvm-gradle-java-version))
           (format "JDK %s for Gradle imports is not installed" my-jvm-gradle-java-version))
          ((and (not kotlin) (not (my-jvm-jdtls-java)))
           "Java 25+ for jdtls not found; install kotlin-lsp or set `my-jvm-jdtls-java-home'"))))

(defun my-jvm-eglot-setup ()
  "Connect Eglot asynchronously, or say what to install; never block visiting the file."
  (if-let* ((missing (my-jvm-missing)))
      (message "Java/Kotlin navigation is off: %s" missing)
    (eglot-ensure)))

(defvar-local my-jvm--resolved nil
  "Resolve replies keyed by the item Eglot sent, as in Eglot's own cache.")

(defun my-jvm-remember-resolved (request server method params &rest args)
  "Call REQUEST; in JVM buffers keep a `completionItem/resolve' reply for PARAMS."
  (let ((reply (apply request server method params args)))
    (when (and my-jvm--resolved (eq method :completionItem/resolve) reply)
      (puthash params reply my-jvm--resolved))
    reply))

(defun my-jvm-completion-at-point ()
  "`eglot-completion-at-point', also running the chosen item's server command.
Eglot 31 ignores CompletionItem.command, yet Kotlin LSP inserts the item and its
import only through that command (its textEdit is empty)."
  (when-let* ((capf (eglot-completion-at-point)))
    (pcase-let ((`(,_ ,_ ,table . ,props) capf))
      (append (seq-take capf 3)
              (plist-put (copy-sequence props) :exit-function
                         (lambda (proxy status)
                           ;; *Completions* passes a bare string; find its item as Eglot does.
                           (let ((item (get-text-property
                                        0 'eglot--lsp-item
                                        (if (get-text-property 0 'eglot--lsp-item proxy) proxy
                                          (or (car (member proxy (all-completions "" table))) "")))))
                             (funcall (plist-get props :exit-function) proxy status)
                             (when-let* (((memq status '(finished exact)))
                                         (command (plist-get (or (and my-jvm--resolved item
                                                                      (gethash item my-jvm--resolved))
                                                                 item)
                                                             :command))
                                         (server (eglot--current-server-or-lose))
                                         ;; Client-side commands (e.g. VS Code's) are not the server's to run.
                                         ((seq-contains-p (eglot-server-capable :executeCommandProvider :commands)
                                                          (plist-get command :command))))
                               (with-demoted-errors "Completion command failed: %S"
                                 ;; Synchronous: the server's edit lands before further typing.
                                 (eglot-execute server (copy-sequence command)))))))))))

(cl-defstruct (my-jvm-content-location (:constructor my-jvm-content-location (uri range server)))
  "A definition inside a dependency, e.g. a jar: class, served by SERVER."
  uri range server)

(defvar my-jvm--content-buffers (make-hash-table :test #'eq :weakness 'key)
  "Server instance to a table of URI to read-only buffer.
Per server: after `eglot-reconnect' the same URI may hold other content.")

(defun my-jvm-content-buffer (server uri)
  "Read-only buffer with SERVER's `workspace/textDocumentContent' for URI."
  (let* ((buffers (or (gethash server my-jvm--content-buffers)
                      (puthash server (make-hash-table :test #'equal) my-jvm--content-buffers)))
         (buffer (gethash uri buffers)))
    (if (buffer-live-p buffer) buffer
      (let ((text (condition-case err
                      (plist-get (jsonrpc-request server :workspace/textDocumentContent (list :uri uri))
                                 :text)
                    (jsonrpc-error (user-error "Cannot open %s: %s" uri
                                               (alist-get 'jsonrpc-error-message (cdr err)))))))
        (unless (stringp text) (user-error "Cannot open %s: the server sent no text" uri))
        (with-current-buffer (generate-new-buffer
                              (format "%s (%s)" (file-name-nondirectory uri)
                                      (file-name-nondirectory (car (split-string uri "!")))))
          (insert text)
          ;; Kotlin LSP renders compiled classes as Kotlin stubs.  No mode hooks: not a project file.
          (delay-mode-hooks (if (string-suffix-p ".java" uri) (java-mode) (kotlin-mode)))
          (setq buffer-read-only t)
          (set-buffer-modified-p nil)
          (puthash uri (current-buffer) buffers))))))

(cl-defmethod xref-location-marker ((l my-jvm-content-location))
  (with-current-buffer (my-jvm-content-buffer (my-jvm-content-location-server l)
                                              (my-jvm-content-location-uri l))
    (save-restriction
      (widen)
      (copy-marker (car (eglot-range-region (my-jvm-content-location-range l)))))))

(cl-defmethod xref-location-group ((l my-jvm-content-location))
  (my-jvm-content-location-uri l))

(cl-defmethod xref-location-line ((l my-jvm-content-location))
  (1+ (plist-get (plist-get (my-jvm-content-location-range l) :start) :line)))

(defun my-jvm-xref-make-match (make name uri range)
  "Keep a definition the server serves as content, e.g. jar:, off the file system.
Eglot 31 would visit `jar:///...!/X.class' as a local file."
  (let ((uri (if (keywordp uri) (substring (symbol-name uri) 1) uri)))
    (if (and (string-match "\\`\\([a-z]+\\):" uri)
             (not (equal (match-string 1 uri) "file"))
             (seq-contains-p (eglot-server-capable :workspace :textDocumentContent :schemes)
                             (match-string 1 uri)))
        (xref-make name (my-jvm-content-location uri range (eglot--current-server-or-lose)))
      (funcall make name uri range))))

(defun my-jvm-completion-setup ()
  "Pop up Corfu with Eglot's completion while Eglot manages the buffer."
  (when (derived-mode-p 'java-mode 'java-ts-mode 'kotlin-mode 'kotlin-ts-mode)
    (if (eglot-managed-p)
        (progn
          (remove-hook 'completion-at-point-functions #'eglot-completion-at-point t)
          (add-hook 'completion-at-point-functions #'my-jvm-completion-at-point nil t)
          (setq-local my-jvm--resolved (make-hash-table :test #'eq :weakness 'key))
          (setq-local corfu-auto t corfu-auto-prefix 1 corfu-auto-delay 0.1
                      corfu-auto-trigger ".")
          (corfu-mode 1))
      (remove-hook 'completion-at-point-functions #'my-jvm-completion-at-point t)
      (kill-local-variable 'my-jvm--resolved)
      (corfu-mode -1)
      (mapc #'kill-local-variable
            '(corfu-auto corfu-auto-prefix corfu-auto-delay corfu-auto-trigger)))))

(add-to-list 'eglot-server-programs '((kotlin-mode kotlin-ts-mode) . my-jvm-kotlin-contact))
(add-to-list 'eglot-server-programs '((java-mode java-ts-mode) . my-jvm-jdtls-contact))
(dolist (hook '(java-mode-hook java-ts-mode-hook kotlin-mode-hook kotlin-ts-mode-hook))
  (add-hook hook #'my-jvm-eglot-setup))
(add-hook 'eglot-managed-mode-hook #'my-jvm-completion-setup)
(advice-add 'eglot--request :around #'my-jvm-remember-resolved)
(advice-add 'eglot--xref-make-match :around #'my-jvm-xref-make-match)

(provide 'my-jvm)
;;; jvm.el ends here
