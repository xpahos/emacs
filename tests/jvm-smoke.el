;;; jvm-smoke.el --- Real Kotlin LSP and JDT LS on two same-named copies -*- lexical-binding: t; -*-
;; Needs kotlin-lsp, jdtls and JDKs 17 and 21+ (see README "Java and Kotlin").
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(setq backtrace-on-error-noninteractive nil)

(defun my-jvm-smoke-write (root file text)
  (let ((path (expand-file-name file root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert text))
    path))

(defconst my-jvm-smoke-template
  (let ((value (getenv "EMACS_TEST_JVM_GRADLE_TEMPLATE")))
    (unless (and value (file-executable-p (expand-file-name "gradlew" value)))
      (error "EMACS_TEST_JVM_GRADLE_TEMPLATE must name a Gradle checkout (e.g. configuration-prod)"))
    (file-name-as-directory (expand-file-name value)))
  "Checkout whose wrapper and plugin repositories the fixtures reuse.")

(defun my-jvm-smoke-gradle (root)
  "Make ROOT a Kotlin JVM Gradle build using the template's wrapper and repositories."
  (copy-file (expand-file-name "gradlew" my-jvm-smoke-template) (expand-file-name "gradlew" root))
  (copy-directory (expand-file-name "gradle" my-jvm-smoke-template) (expand-file-name "gradle" root))
  (let ((settings (with-temp-buffer
                    (insert-file-contents (expand-file-name "settings.gradle.kts" my-jvm-smoke-template))
                    (goto-char (point-min))
                    (if (re-search-forward "^pluginManagement {\\(?:.\\|\n\\)*?^}\n" nil t)
                        (match-string 0) ""))))
    (my-jvm-smoke-write root "settings.gradle.kts" (concat settings "rootProject.name = \"demo\"\n")))
  (my-jvm-smoke-write root "build.gradle.kts" "\
plugins { kotlin(\"jvm\") version \"1.7.10\" }
repositories { mavenLocal(); bucket(\"central\"); mavenCentral() }
fun RepositoryHandler.bucket(repo: String) = maven {
    setUrl(\"https://bucket.yandex-team.ru/v1/maven/${repo}\")
    credentials(PasswordCredentials::class) {
        username = project.property(\"bucketUsername\").toString()
        password = project.property(\"bucketPassword\").toString()
    }
}
"))

(defun my-jvm-smoke-copy (base copy)
  "Create project `demo' under BASE/COPY whose declarations are named after COPY."
  (let ((root (file-name-as-directory (file-truename (expand-file-name (concat copy "/demo") base)))))
    (make-directory root t)
    (my-jvm-smoke-gradle root)
    (my-jvm-smoke-write root "src/main/kotlin/demo/Greeter.kt"
                        (format "package demo\n\nclass Greeter {\n    fun hello_%s(): String = \"%s\"\n}\n" copy copy))
    (my-jvm-smoke-write root "src/main/kotlin/demo/Main.kt"
                        "package demo\n\nfun main() {\n    val g = Greeter()\n    println(g.hello)\n    println(Util.twice(1))\n}\n")
    (my-jvm-smoke-write root "src/main/java/demo/Util.java"
                        "package demo;\n\npublic class Util {\n    public static int twice(int x) { return 2 * x; }\n}\n")
    (my-jvm-smoke-write root "src/main/java/demo/App.java"
                        "package demo;\n\npublic class App {\n    public static void main(String[] a) {\n        System.out.println(Util.twice(2));\n        new Greeter();\n    }\n}\n")
    root))

(defun my-jvm-smoke-wait (what seconds fn)
  "Poll FN until non-nil for SECONDS, signalling WHAT with the last error on timeout."
  (let ((deadline (+ (float-time) seconds)) result last-error)
    (while (and (not result) (< (float-time) deadline))
      (condition-case err (setq result (funcall fn))
        (error (setq last-error err)))
      (unless result (accept-process-output nil 0.5)))
    (or result (error "%s: none after %ss (%S)" what seconds last-error))))

(defun my-jvm-smoke-definition (search &optional seconds)
  "Definition file of the identifier at the end of SEARCH, or nil on timeout."
  (goto-char (point-min))
  (search-forward search)
  (backward-char 1)
  (condition-case nil
      (my-jvm-smoke-wait search (or seconds 180)
                         (lambda ()
                           (when-let* ((defs (xref-backend-definitions
                                              'eglot (xref-backend-identifier-at-point 'eglot))))
                             (file-truename (xref-file-location-file (xref-item-location (car defs)))))))
    (error nil)))

(defun my-jvm-smoke-candidates (after)
  "Server completion candidates with point just after AFTER."
  (goto-char (point-min))
  (search-forward after)
  (my-jvm-smoke-wait (concat "completion after " after) 60
                     (lambda ()
                       (pcase-let ((`(,beg ,end ,table . ,_) (my-jvm-completion-at-point)))
                         (all-completions (buffer-substring-no-properties beg end) table)))))

(defun my-jvm-smoke-open (file mode)
  "Visit FILE, check MODE and wait until Eglot manages it."
  (find-file file)
  (cl-assert (eq major-mode mode) nil "%s opened in %s" file major-mode)
  (run-hooks 'post-command-hook)
  (my-jvm-smoke-wait (format "Eglot for %s" file) 60 #'eglot-managed-p)
  (cl-assert corfu-mode) (cl-assert corfu-auto)
  (cl-assert (memq #'my-jvm-completion-at-point completion-at-point-functions))
  (eglot-current-server))

(let* ((base (file-truename (make-temp-file "emacs-jvm-smoke-" t)))
       (roots (mapcar (lambda (copy) (my-jvm-smoke-copy base copy)) '("a" "b")))
       (eglot-connect-timeout 120)
       (project--list nil)
       (report nil)
       servers)
  (unwind-protect
      (progn
        (dolist (root roots)
          (let ((copy (file-name-nondirectory (directory-file-name (file-name-directory (directory-file-name root))))))
            (my-project-open root)
            ;; Kotlin: cross-file definition stays in this copy, member completion, import edit.
            (let ((server (my-jvm-smoke-open (expand-file-name "src/main/kotlin/demo/Main.kt" root) 'kotlin-mode)))
              (push server servers)
              (cl-assert (equal (file-truename (project-root (eglot--project server))) root))
              (cl-assert (equal (my-jvm-smoke-definition "Greeter(")
                                (expand-file-name "src/main/kotlin/demo/Greeter.kt" root)))
              (let ((cands (my-jvm-smoke-candidates "g.hello")))
                (cl-assert (member (concat "hello_" copy) cands) nil "Kotlin candidates %S" cands)
                (cl-assert (not (member (if (equal copy "a") "hello_b" "hello_a") cands))))
              (push (format "Kotlin -> Java (Util.twice) in %s: %s" copy
                            (or (my-jvm-smoke-definition "Util." 60) "unresolved"))
                    report)
              (goto-char (point-max))
              (insert "val m = ConcurrentHashM")
              (pcase-let* ((`(,beg ,end ,table . ,props)
                            (my-jvm-smoke-wait "ConcurrentHashMap completion" 60
                                               (lambda () (let ((r (my-jvm-completion-at-point)))
                                                            (and (member "ConcurrentHashMap"
                                                                         (all-completions "ConcurrentHashM" (nth 2 r)))
                                                                 r)))))
                           (choice (car (member "ConcurrentHashMap" (all-completions "ConcurrentHashM" table)))))
                (delete-region beg end)
                (insert choice)
                (funcall (plist-get props :exit-function) choice 'finished))
              ;; Kotlin LSP inserts through a server command, which arrives as workspace/applyEdit.
              (my-jvm-smoke-wait "import edit" 30
                                 (lambda () (save-excursion
                                              (goto-char (point-min))
                                              (and (search-forward "import java.util.concurrent.ConcurrentHashMap" nil t)
                                                   (search-forward "= ConcurrentHashMap" nil t)))))
              (set-buffer-modified-p nil))
            ;; Java: cross-file definition and member completion.
            (let ((server (my-jvm-smoke-open (expand-file-name "src/main/java/demo/App.java" root) 'java-mode)))
              (push server servers)
              (cl-assert (equal (file-truename (project-root (eglot--project server))) root))
              (cl-assert (equal (my-jvm-smoke-definition "Util.twice")
                                (expand-file-name "src/main/java/demo/Util.java" root)))
              (let ((cands (my-jvm-smoke-candidates "Util.tw")))
                (cl-assert (seq-find (lambda (c) (string-prefix-p "twice" c)) cands) nil "Java candidates %S" cands))
              (push (format "Java -> Kotlin (Greeter) in %s: %s" copy
                            (or (my-jvm-smoke-definition "new Greeter" 30) "unresolved"))
                    report))))
        (cl-assert (= 4 (length (delete-dups (copy-sequence servers)))))
        (let ((states (mapcar (lambda (s) (car (last (process-command (jsonrpc--process s))))) servers)))
          (cl-assert (= 4 (length (delete-dups states)))))
        ;; Closing each project tab kills its buffers; Eglot then shuts its servers down.
        (while (> (length (tab-bar-tabs)) 1) (tab-bar-close-tab (length (tab-bar-tabs))))
        (my-jvm-smoke-wait "server shutdown" 60
                           (lambda () (seq-every-p (lambda (s) (not (jsonrpc-running-p s))) servers)))
        ;; Reopening the copy restores its files and starts a fresh server.
        (my-project-open (car roots))
        (let ((buffer (find-buffer-visiting (expand-file-name "src/main/kotlin/demo/Main.kt" (car roots)))))
          (cl-assert buffer nil "Project reopen did not restore Main.kt")
          (with-current-buffer buffer
            (run-hooks 'post-command-hook)
            (my-jvm-smoke-wait "Eglot after reopen" 60 #'eglot-managed-p)
            (cl-assert (not (memq (eglot-current-server) servers)))))
        (dolist (line (nreverse report)) (princ (concat line "\n")))
        (princ "Kotlin and Java servers: definitions, completion and import edits per copy; shutdown and reopen.\n"))
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
       (with-current-buffer buffer
        (when (and buffer-file-name (file-in-directory-p buffer-file-name base))
          (set-buffer-modified-p nil)
          (when-let* ((server (eglot-current-server))) (ignore-errors (eglot-shutdown server)))
          (kill-buffer buffer)))))
    (delete-directory base t)))
