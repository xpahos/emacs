;;; jvm-tests.el --- Java and Kotlin Eglot setup, no servers -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'package)
(setq package-user-dir (expand-file-name "../elpa" (file-name-directory load-file-name))
      user-emacs-directory (file-name-as-directory (make-temp-file "emacs-jvm-tests-" t)))
(package-initialize)
(defconst my-jvm-test-file (expand-file-name "../jvm.el" (file-name-directory load-file-name)))
(load my-jvm-test-file nil t)

(defmacro my-jvm-test-buffer (file &rest body)
  "Visit FILE (relative to a fresh temporary root) without starting servers; run BODY."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "jvm-root-" t)))
          (path (expand-file-name ,file root))
          (ensured 0))
     (cl-letf (((symbol-function 'eglot-ensure) (lambda () (cl-incf ensured))))
       (unwind-protect
           (with-current-buffer (find-file-noselect path)
             (unwind-protect (progn ,@body)
               (set-buffer-modified-p nil)
               (kill-buffer)))
         (delete-directory root t)))))

(ert-deftest my-jvm-kotlin-files-use-kotlin-mode ()
  (dolist (file '("Main.kt" "build.gradle.kts"))
    (my-jvm-test-buffer file
      (should (eq major-mode 'kotlin-mode)))))

(ert-deftest my-jvm-java-files-use-builtin-java-mode ()
  (my-jvm-test-buffer "Main.java"
    (should (eq major-mode 'java-mode))))

(ert-deftest my-jvm-modes-select-their-servers ()
  (should (eq (cdr (eglot--lookup-mode 'kotlin-mode)) #'my-jvm-kotlin-contact))
  (should (eq (cdr (eglot--lookup-mode 'java-mode)) #'my-jvm-jdtls-contact)))

(ert-deftest my-jvm-opening-starts-eglot-when-servers-exist ()
  (cl-letf (((symbol-function 'my-jvm-missing) #'ignore))
    (dolist (file '("A.kt" "A.java"))
      (my-jvm-test-buffer file
        (should (= ensured 1))))))

(ert-deftest my-jvm-missing-server-warns-and-opens-file ()
  (let ((exec-path nil) (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format-message fmt args) messages))))
      (my-jvm-test-buffer "A.kt"
        (should (eq major-mode 'kotlin-mode))
        (should (= ensured 0))
        (should (string-match-p "kotlin-lsp.*README" (car messages))))
      (my-jvm-test-buffer "A.java"
        (should (= ensured 0))
        (should (string-match-p "jdtls.*README" (car messages)))))))

(defun my-jvm-test-jdk (dir major)
  "Make DIR look like a JDK home of MAJOR version; return it."
  (make-directory dir t)
  (with-temp-file (expand-file-name "release" dir)
    (insert (format "IMPLEMENTOR=\"Test\"\nJAVA_VERSION=\"%s.0.1\"\n" major)))
  dir)

(ert-deftest my-jvm-java-home-rejects-other-versions ()
  ;; java_home answers an absent version with another JDK and exit status 0.
  (let ((jdk (my-jvm-test-jdk (make-temp-file "jvm-jdk-" t) 23)))
    (unwind-protect
        (cl-letf (((symbol-function 'call-process)
                   (lambda (&rest _) (insert jdk "\n") 0)))
          (should (equal (my-jvm-java-home 23) jdk))
          (should-not (my-jvm-java-home 17)))
      (delete-directory jdk t))))

(ert-deftest my-jvm-jdtls-runs-on-java-25 ()
  (let* ((base (file-truename (make-temp-file "jvm-jbr-" t)))
         (old (my-jvm-test-jdk (expand-file-name "jdk23" base) 23))
         (jbr (my-jvm-test-jdk (expand-file-name "lsp/jbr/Contents/Home" base) 25))
         (lsp (expand-file-name "lsp/bin/intellij-server" base)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory lsp) t)
          (with-temp-file lsp)
          (cl-letf (((symbol-function 'executable-find) (lambda (_) lsp)))
            (let ((my-jvm-jdtls-java-home nil))
              (should (equal (my-jvm-jdtls-java) (expand-file-name "bin/java" jbr))))
            (let ((my-jvm-jdtls-java-home old))
              (should-not (my-jvm-jdtls-java)))))
      (delete-directory base t))))

(ert-deftest my-jvm-missing-jdk-is-reported ()
  (cl-letf (((symbol-function 'my-jvm-java-home) #'ignore)
            ((symbol-function 'my-jvm-jdtls-java) #'ignore)
            ((symbol-function 'executable-find) #'identity))
    (with-temp-buffer
      (setq major-mode 'kotlin-mode)
      (should (string-match-p "JDK 17" (my-jvm-missing))))
    (cl-letf (((symbol-function 'my-jvm-java-home) (lambda (_) "/jdk")))
      (with-temp-buffer
        (setq major-mode 'java-mode)
        (should (string-match-p "Java 25" (my-jvm-missing)))))))

(ert-deftest my-jvm-commands-pin-jdks-and-state ()
  (cl-letf (((symbol-function 'my-jvm-java-home) (lambda (v) (format "/jdk-%s" v)))
            ((symbol-function 'my-jvm-jdtls-java) (lambda () "/jbr/bin/java")))
    (let* ((root (file-name-as-directory (make-temp-file "jvm-cmd-" t)))
           (project (cons 'transient root))
           (kotlin (my-jvm-kotlin-contact nil project))
           (java (my-jvm-jdtls-contact nil project)))
      (unwind-protect
          (progn
            (should (equal (seq-take kotlin 4) '("env" "JAVA_HOME=/jdk-17" "kotlin-lsp" "--stdio")))
            (should (equal (nth 4 kotlin)
                           (concat "--system-path=" (my-jvm-state-directory "kotlin" root))))
            ;; The default index is keyed by root path and locked by one server.
            (should (equal (cadr (memq :initializationOptions kotlin))
                           (list :indexDir (expand-file-name "index" (my-jvm-state-directory "kotlin" root)))))
            (should (equal (seq-take java 3) '("jdtls" "--java-executable" "/jbr/bin/java")))
            ;; Without a private -configuration, every instance writes the installation's
            ;; OSGi area, and stopping one copy's server killed another copy's.
            (should (equal (seq-subseq java 3 7)
                           (list "-data" (expand-file-name "data" (my-jvm-state-directory "jdtls" root))
                                 "-configuration"
                                 (expand-file-name "configuration" (my-jvm-state-directory "jdtls" root)))))
            (should (equal (plist-get (cadr (memq :initializationOptions java)) :settings)
                           '(:java (:import (:gradle (:java (:home "/jdk-17"))))))))
        (delete-directory root t)))))

(ert-deftest my-jvm-same-named-projects-get-separate-state ()
  (let* ((base (file-name-as-directory (make-temp-file "jvm-copies-" t)))
         (a (expand-file-name "copy-a/configuration-prod/" base))
         (b (expand-file-name "copy-b/configuration-prod/" base))
         (link (expand-file-name "link" base)))
    (unwind-protect
        (progn
          (make-directory a t) (make-directory b t)
          (make-symbolic-link a link)
          (should-not (equal (my-jvm-state-directory "jdtls" a) (my-jvm-state-directory "jdtls" b)))
          (should-not (equal (my-jvm-state-directory "kotlin" a) (my-jvm-state-directory "jdtls" a)))
          ;; Canonical path: a symlinked spelling of the same copy shares its state.
          (should (equal (my-jvm-state-directory "kotlin" a) (my-jvm-state-directory "kotlin" link)))
          (should (file-in-directory-p (my-jvm-state-directory "kotlin" a) user-emacs-directory)))
      (delete-directory base t))))

(ert-deftest my-jvm-corfu-follows-eglot-management ()
  (my-jvm-test-buffer "A.kt"
    (add-hook 'completion-at-point-functions #'eglot-completion-at-point nil t)
    (cl-letf (((symbol-function 'eglot-managed-p) #'always))
      (my-jvm-completion-setup)
      (should corfu-mode)
      (should corfu-auto)
      (should (equal corfu-auto-trigger "."))
      (should (equal (remq t completion-at-point-functions) '(my-jvm-completion-at-point))))
    (cl-letf (((symbol-function 'eglot-managed-p) #'ignore))
      (my-jvm-completion-setup)
      (should-not corfu-mode)
      (should-not (local-variable-p 'corfu-auto))
      (should-not (memq #'my-jvm-completion-at-point completion-at-point-functions))))
  (with-temp-buffer
    (cl-letf (((symbol-function 'eglot-managed-p) #'always))
      (my-jvm-completion-setup)
      (should-not corfu-mode))))

(defun my-jvm-test-complete (&rest spec)
  "Complete `ConcurrentHashM' through the real Eglot CAPF with replies from SPEC.
SPEC: :command (on the item), :resolved-command (only after resolve),
:plain (exit gets a string without properties), :status.  Return
(BUFFER-TEXT EXECUTED RESOLVES)."
  (let* ((executed 0) (resolves 0)
         (apply-cmd (lambda (name) (and name (list :title "Apply" :command name :arguments [1]))))
         (item `(:label "ConcurrentHashMap" :sortText "0"
                 ;; Kotlin LSP style: the edit only removes the prefix; the command inserts.
                 :textEdit (:newText "" :range (:start (:line 0 :character 8) :end (:line 0 :character 23)))
                 :data (:key 1)
                 ,@(when (plist-get spec :command) (list :command (funcall apply-cmd (plist-get spec :command)))))))
    (with-temp-buffer
      (insert "val m = ConcurrentHashM")
      (setq-local my-jvm--resolved (make-hash-table :test #'eq :weakness 'key))
      (cl-letf (((symbol-function 'eglot--current-server-or-lose) (lambda () 'server))
                ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
                ((symbol-function 'eglot--CompletionParams) (lambda () '(:position nil)))
                ((symbol-function 'jsonrpc-notify) #'ignore)
                ((symbol-function 'eglot-server-capable)
                 (lambda (&rest feats)
                   (pcase feats
                     (`(:completionProvider) '(:resolveProvider t))
                     (`(:completionProvider :resolveProvider) t)
                     (`(:executeCommandProvider :commands) ["test.apply"]))))
                ((symbol-function 'jsonrpc-request)
                 (lambda (_server method params &rest _)
                   (pcase method
                     (:textDocument/completion `(:isIncomplete t :items [,item]))
                     (:completionItem/resolve
                      (cl-incf resolves)
                      (append (when (plist-get spec :resolved-command)
                                (list :command (funcall apply-cmd (plist-get spec :resolved-command))))
                              params))
                     (:workspace/executeCommand
                      (cl-incf executed)
                      ;; The server's applyEdit inserts the completed name.
                      (insert "ConcurrentHashMap")
                      nil)))))
        (pcase-let* ((`(,beg ,end ,table . ,props) (my-jvm-completion-at-point))
                     (cand (car (all-completions (buffer-substring beg end) table))))
          (delete-region beg end)
          (insert cand)
          (funcall (plist-get props :exit-function)
                   (if (plist-get spec :plain) (substring-no-properties cand) cand)
                   (or (plist-get spec :status) 'finished))))
      (list (buffer-string) executed resolves))))

(ert-deftest my-jvm-completion-runs-the-selected-items-command ()
  (should (equal (my-jvm-test-complete :command "test.apply")
                 '("val m = ConcurrentHashMap" 1 1))))

(ert-deftest my-jvm-completion-command-survives-plain-candidates ()
  ;; Selecting through *Completions* passes the string without its item.
  (should (equal (my-jvm-test-complete :command "test.apply" :plain t)
                 '("val m = ConcurrentHashMap" 1 1))))

(ert-deftest my-jvm-completion-runs-a-command-from-resolve ()
  (should (equal (my-jvm-test-complete :resolved-command "test.apply")
                 '("val m = ConcurrentHashMap" 1 1))))

(ert-deftest my-jvm-completion-skips-client-side-commands ()
  ;; JDT LS items carry VS Code commands that are not the server's to run.
  (should (equal (cadr (my-jvm-test-complete :command "editor.action.triggerParameterHints")) 0)))

(ert-deftest my-jvm-completion-skips-unaccepted-candidates ()
  (should (equal (cadr (my-jvm-test-complete :command "test.apply" :status 'sole)) 0)))

(defmacro my-jvm-test-definitions (location content &rest body)
  "Run BODY in a Kotlin file whose server answers definitions with LOCATION.
CONTENT is the `workspace/textDocumentContent' reply, or an error message."
  (declare (indent 2))
  `(let* ((dir (file-truename (make-temp-file "jvm-xref-" t)))
          (file (expand-file-name "Main.kt" dir))
          (requests nil))
     (unwind-protect
         (with-current-buffer (find-file-noselect file)
           (insert "val app = Application\n")
           (cl-letf (((symbol-function 'eglot--current-server-or-lose) (lambda () 'server))
                     ((symbol-function 'eglot-current-server) (lambda () nil))
                     ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
                     ((symbol-function 'eglot-server-capable)
                      (lambda (&rest feats)
                        (pcase feats
                          (`(:workspace :textDocumentContent :schemes) ["jar" "jrt"])
                          (_ t))))
                     ((symbol-function 'jsonrpc-request)
                      (lambda (server method params &rest _)
                        (push (list server method params) requests)
                        (pcase method
                          (:textDocument/definition (vector ,location))
                          (:workspace/textDocumentContent
                           (if (stringp ,content) (list :text ,content)
                             (signal 'jsonrpc-error
                                     '("request failed" (jsonrpc-error-code . -32603)
                                       (jsonrpc-error-message . "no such entry")))))))))
             (setq-local xref-backend-functions (list (lambda () 'eglot)))
             (goto-char (point-min))
             (search-forward "Applic")
             ,@body))
       (dolist (b (buffer-list))
         (when (string-match-p "Application\\.class" (buffer-name b)) (kill-buffer b)))
       (when-let* ((b (find-buffer-visiting file)))
         (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
       (delete-directory dir t))))

(defconst my-jvm-test-jar-uri
  "jar:///cache/spinnaker-dsl-0.82.20.jar!/yandex/cloud/spinnaker/dsl/Application.class")

(ert-deftest my-jvm-jar-definitions-open-read-only-server-content ()
  (my-jvm-test-definitions
      `(:uri ,my-jvm-test-jar-uri :range (:start (:line 2 :character 6) :end (:line 2 :character 17)))
      "package yandex.cloud.spinnaker.dsl\n\nclass Application {\n}\n"
    (let ((source (current-buffer)) (origin (point)))
      (xref-find-definitions "Application")
      (should-not (eq (current-buffer) source))
      (should buffer-read-only)
      (should-not buffer-file-name)
      (should (looking-at "Application {"))
      (should (= (line-number-at-pos) 3))
      ;; Served by the server that returned the definition, for that URI only.
      (should (equal (seq-find (lambda (r) (eq (nth 1 r) :workspace/textDocumentContent)) requests)
                     `(server :workspace/textDocumentContent (:uri ,my-jvm-test-jar-uri))))
      (xref-go-back)
      (should (eq (current-buffer) source))
      (should (= (point) origin)))))

(ert-deftest my-jvm-jar-content-failure-is-reported ()
  (my-jvm-test-definitions
      `(:uri ,my-jvm-test-jar-uri :range (:start (:line 0 :character 0) :end (:line 0 :character 1)))
      nil
    (let ((err (should-error (xref-location-marker
                              (xref-item-location
                               (car (xref-backend-definitions 'eglot "Application"))))
                             :type 'user-error)))
      (should (string-match-p "Application\\.class.*no such entry" (cadr err))))))

(ert-deftest my-jvm-file-definitions-stay-file-locations ()
  (my-jvm-test-definitions
      `(:uri ,(concat "file://" (expand-file-name "Other.kt" temporary-file-directory))
        :range (:start (:line 0 :character 0) :end (:line 0 :character 1)))
      nil
    (should (xref-file-location-p
             (xref-item-location (car (xref-backend-definitions 'eglot "Application")))))))

(ert-deftest my-jvm-content-cache-is-per-server ()
  ;; After `eglot-reconnect' a new server may serve other content under the same URI
  ;; (e.g. an updated SNAPSHOT jar).
  (let ((my-jvm--content-buffers (make-hash-table :test #'eq :weakness 'key))
        (replies '((server-a . "class Application { fun oldMethod() {} }\n")
                   (server-b . "class Application { fun newMethod() {} }\n")))
        (requests nil)
        (created nil))
    (cl-letf (((symbol-function 'jsonrpc-request)
               (lambda (server method params &rest _)
                 (push (list server method params) requests)
                 (list :text (alist-get server replies)))))
      (unwind-protect
          (let* ((a (car (push (my-jvm-content-buffer 'server-a my-jvm-test-jar-uri) created)))
                 (b (car (push (my-jvm-content-buffer 'server-b my-jvm-test-jar-uri) created))))
            (should (equal (reverse requests)
                           `((server-a :workspace/textDocumentContent (:uri ,my-jvm-test-jar-uri))
                             (server-b :workspace/textDocumentContent (:uri ,my-jvm-test-jar-uri)))))
            (should-not (eq a b))
            (dolist (pair `((,a . "oldMethod") (,b . "newMethod")))
              (with-current-buffer (car pair)
                (should buffer-read-only)
                (should (string-match-p (cdr pair) (buffer-string)))))
            (should (eq (my-jvm-content-buffer 'server-b my-jvm-test-jar-uri) b))
            (should (= 2 (length requests)))
            (kill-buffer b)
            (let ((fresh (my-jvm-content-buffer 'server-b my-jvm-test-jar-uri)))
              (push fresh created)
              (should (= 3 (length requests)))
              (should-not (eq fresh b))
              (should (string-match-p "newMethod" (with-current-buffer fresh (buffer-string))))))
        (dolist (b created) (when (buffer-live-p b) (kill-buffer b)))))))

(ert-deftest my-jvm-reload-does-not-duplicate ()
  (load my-jvm-test-file nil t)
  (load my-jvm-test-file nil t)
  (should (= 1 (cl-count #'my-jvm-kotlin-contact eglot-server-programs :key #'cdr)))
  (should (= 1 (cl-count #'my-jvm-jdtls-contact eglot-server-programs :key #'cdr)))
  (dolist (hook '(java-mode-hook kotlin-mode-hook))
    (should (= 1 (cl-count #'my-jvm-eglot-setup (symbol-value hook)))))
  (should (= 1 (cl-count #'my-jvm-completion-setup eglot-managed-mode-hook)))
  (should (= 1 (let ((n 0))
                 (advice-mapc (lambda (f _) (when (eq f 'my-jvm-remember-resolved) (cl-incf n)))
                              'eglot--request)
                 n)))
  (should (= 1 (let ((n 0))
                 (advice-mapc (lambda (f _) (when (eq f 'my-jvm-xref-make-match) (cl-incf n)))
                              'eglot--xref-make-match)
                 n))))

;;; jvm-tests.el ends here
