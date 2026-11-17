;;; worktrees-tests.el --- Working copies, migration and project-wide history -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'package)
(defconst my-wt-test-config (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(setq user-emacs-directory (file-name-as-directory (file-truename (make-temp-file "emacs-worktree-tests-" t)))
      package-user-dir (expand-file-name "elpa" my-wt-test-config))
(package-initialize)
(load (expand-file-name "projects.el" my-wt-test-config) nil t)
(load (expand-file-name "pi-history-worker.el" my-wt-test-config) nil t)
(load (expand-file-name "project-search.el" my-wt-test-config) nil t)
(load (expand-file-name "tests/pi-history-fixtures.el" my-wt-test-config) nil t)

(defmacro my-wt-test (&rest body)
  "Run BODY with a fresh catalogue, temporary directories and one Start tab."
  `(let* ((user-emacs-directory (file-name-as-directory (file-truename (make-temp-file "wt-home-" t))))
          (my-pi-history-db nil)
          (my-wt-states (make-hash-table :test #'equal))
          (my-wt-busy (make-hash-table :test #'equal))
          (my-wt-branches (make-hash-table :test #'equal))
          (my-wt-arc-mounts-cache nil)
          (project--list nil)
          (project-list-file (expand-file-name "projects.eld" user-emacs-directory))
          (tmp (file-name-as-directory (file-truename (make-temp-file "wt-src-" t)))))
     (unwind-protect
         (progn
           (switch-to-buffer (get-buffer-create "*scratch*"))
           (delete-other-windows)
           (set-frame-parameter nil 'tabs nil)
           (tab-bar-mode 1)
           (tab-bar-rename-tab "Start")
           ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (or (file-in-directory-p (buffer-file-name buffer) tmp)
                        (file-in-directory-p (buffer-file-name buffer) user-emacs-directory)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (while (> (length (tab-bar-tabs)) 1) (tab-bar-close-tab (length (tab-bar-tabs))))
       (when my-pi-history-db (sqlite-close my-pi-history-db))
       (delete-directory tmp t)
       (delete-directory user-emacs-directory t))))

(defun my-wt-test-wait (predicate &optional seconds)
  (let ((deadline (+ (float-time) (or seconds 20))))
    (while (and (not (funcall predicate)) (< (float-time) deadline)) (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defun my-wt-test-git (dir &rest args)
  (let ((result (apply #'my-wt-call dir "git" args)))
    (unless (zerop (car result)) (error "git %S failed: %s" args (cdr result)))
    (string-trim (cdr result))))

(defun my-wt-test-repo (dir)
  "A Git repository in DIR with one commit on main and a sub/ project."
  (make-directory (expand-file-name "sub" dir) t)
  (my-wt-test-git dir "init" "-q" "-b" "main")
  (my-wt-test-git dir "config" "user.email" "t@example.com")
  (my-wt-test-git dir "config" "user.name" "Test")
  ;; The user signs commits globally; disposable repositories must not need the key.
  (my-wt-test-git dir "config" "commit.gpgsign" "false")
  (with-temp-file (expand-file-name "sub/a.txt" dir) (insert "a\n"))
  (with-temp-file (expand-file-name ".gitignore" dir) (insert "*.log\n"))
  (my-wt-test-git dir "add" ".")
  (my-wt-test-git dir "commit" "-q" "-m" "init")
  dir)

(defun my-wt-test-create (source spec)
  (let* ((copy (my-wt-create source spec)) (id (plist-get copy :copy_id)))
    (my-wt-test-wait (lambda () (not (gethash id my-wt-busy))))
    (my-wt-copy id)))

(defun my-wt-test-git-copy (source branch)
  "Prepare an existing fixture branch, then create its working copy."
  (my-wt-test-git (plist-get source :vcs_root) "branch" branch)
  (my-wt-test-create source (list :branch branch)))

;;; Registry and migration

(defun my-wt-test-v1-db (root other)
  "Write a catalogue in the previous (version 1) schema with real-looking state."
  (make-directory (file-name-directory (my-pi-history-path)) t)
  (let ((db (sqlite-open (my-pi-history-path))))
    (sqlite-execute db "PRAGMA journal_mode=WAL")
    (sqlite-execute db "CREATE TABLE chats (session_id TEXT PRIMARY KEY, project_root TEXT NOT NULL, session_file TEXT,
      title TEXT NOT NULL DEFAULT 'New chat', created_at TEXT NOT NULL, first_prompt_at TEXT, last_reply_at TEXT,
      last_reply_id TEXT, read_reply_id TEXT, turn_state TEXT NOT NULL DEFAULT 'idle', owner_instance TEXT,
      deleting INTEGER NOT NULL DEFAULT 0, fingerprint TEXT, pending_since TEXT)")
    (sqlite-execute db "CREATE TABLE projects (project_root TEXT PRIMARY KEY, selected_session_id TEXT,
      picker_width INTEGER, picker_height INTEGER, picker_left INTEGER, picker_top INTEGER)")
    (sqlite-execute db "CREATE VIRTUAL TABLE messages USING fts5(session_id UNINDEXED, message_id UNINDEXED,
      ordinal UNINDEXED, role UNINDEXED, title, body, tokenize='unicode61')")
    (sqlite-execute db "CREATE TABLE deleted_chats (session_id TEXT PRIMARY KEY)")
    (sqlite-execute db "INSERT INTO chats(session_id,project_root,session_file,title,created_at,last_reply_id,read_reply_id)
      VALUES ('a',?,'/s/a.jsonl','Alpha','2026-01-01','r1','r0'),('b',?,NULL,'Beta','2026-01-02','r2','r2')" (list root other))
    (sqlite-execute db "INSERT INTO messages VALUES ('a','m1',0,'user',NULL,'needle body')")
    (sqlite-execute db "INSERT INTO projects VALUES (?,'a',640,420,10,20)" (list root))
    (sqlite-execute db "INSERT INTO deleted_chats VALUES ('gone')")
    (sqlite-execute db "PRAGMA user_version=1")
    (sqlite-close db)))

(ert-deftest my-wt-migration-preserves-history-and-is-idempotent ()
  (my-wt-test
   (let ((root (expand-file-name "one/service/" tmp)) (other (expand-file-name "two/service/" tmp)))
     (make-directory root t) (make-directory other t)
     (my-wt-test-v1-db root other)
     (let ((db (my-pi-history-open)))
       (should (= (caar (sqlite-select db "PRAGMA user_version")) 3))
       (should (equal (sqlite-select db "SELECT session_id,project_root,session_file,read_reply_id FROM chats ORDER BY 1")
                      `(("a" ,root "/s/a.jsonl" "r0") ("b" ,other nil "r2"))))
       (should (plist-get (my-pi-history-get "a") :unread))
       (should-not (plist-get (my-pi-history-get "b") :unread))
       (should (equal (my-pi-history-selected root) "a"))
       (should (sqlite-select db "SELECT 1 FROM deleted_chats WHERE session_id='gone'"))
       (should (equal (sqlite-select db "SELECT picker_width,picker_left FROM projects") '((640 10))))
       ;; Same directory names never merge: two projects, two originals.
       (should (= (caar (sqlite-select db "SELECT COUNT(DISTINCT project_id) FROM working_copies WHERE role='original'")) 2))
       (should (my-pi-history-query root "needle"))
       (should-not (my-pi-history-query other "needle"))
       (let ((backups (directory-files (expand-file-name "pi/backups/" user-emacs-directory) t "\\.sqlite\\'")))
         (should (= (length backups) 1))
         (let ((backup (sqlite-open (car backups))))
           (should (equal (sqlite-select backup "SELECT COUNT(*) FROM chats") '((2))))
           (should (equal (sqlite-select backup "PRAGMA user_version") '((1))))
           (sqlite-close backup))))
     (let ((ids (sqlite-select my-pi-history-db "SELECT copy_id,project_id FROM working_copies ORDER BY 1")))
       (sqlite-close my-pi-history-db) (setq my-pi-history-db nil)
       (my-pi-history-open)
       (should (equal ids (sqlite-select my-pi-history-db "SELECT copy_id,project_id FROM working_copies ORDER BY 1")))
       (should (= (length (directory-files (expand-file-name "pi/backups/" user-emacs-directory) nil "\\.sqlite\\'")) 1))))))

(ert-deftest my-wt-failed-migration-leaves-version-1-schema ()
  (my-wt-test
   (let ((root (expand-file-name "one/" tmp)) (other (expand-file-name "two/" tmp)))
     (my-wt-test-v1-db root other)
     (cl-letf (((symbol-function 'my-pi-history--ensure-copy) (lambda (&rest _) (error "Injected failure"))))
       (should-error (my-pi-history-open)))
     (should-not my-pi-history-db)
     (let ((db (sqlite-open (my-pi-history-path))))
       (unwind-protect
           (progn
             (should (equal (sqlite-select db "PRAGMA user_version") '((1))))
             (should-not (sqlite-select db "SELECT 1 FROM sqlite_master WHERE name IN ('working_copies','logical_projects')"))
             (should-not (member "branch" (mapcar #'cadr (sqlite-select db "PRAGMA table_info(chats)"))))
             (should (equal (sqlite-select db "SELECT COUNT(*) FROM chats") '((2)))))
         (sqlite-close db)))
     ;; The next open completes the migration.
     (my-pi-history-open)
     (should (= (caar (sqlite-select my-pi-history-db "PRAGMA user_version")) 3)))))

(ert-deftest my-wt-same-name-projects-and-branch-identity ()
  (my-wt-test
   (let ((a (my-wt-test-repo (expand-file-name "a/service/" tmp)))
         (b (expand-file-name "b/service/" tmp)))
     (make-directory b t)
     (let ((ca (my-wt-register a)) (cb (my-wt-register b)))
       (should-not (equal (plist-get ca :project_id) (plist-get cb :project_id)))
       (should (equal (plist-get (my-wt-project (plist-get ca :project_id)) :name)
                      (plist-get (my-wt-project (plist-get cb :project_id)) :name)))
       (should (equal (plist-get ca :vcs) "git"))
       (should (equal (plist-get (my-wt-register (expand-file-name "sub/" a)) :relative_path) "sub/"))
       (my-wt-test-git a "checkout" "-q" "-b" "elsewhere")
       (should (equal (plist-get (my-wt-register a) :copy_id) (plist-get ca :copy_id)))
       (let ((pa (car (my-wt-allocate (my-wt-project (plist-get ca :project_id)) "git" "x")))
             (place-a (cdr (my-wt-allocate (my-wt-project (plist-get ca :project_id)) "git" "x")))
             (place-b (cdr (my-wt-allocate (my-wt-project (plist-get cb :project_id)) "git" "x"))))
         (should (string-prefix-p "x-" pa))
         (should-not (equal (file-name-directory (directory-file-name place-a))
                            (file-name-directory (directory-file-name place-b)))))))))

(ert-deftest my-wt-history-spans-copies-including-deleted ()
  (my-wt-test
   (let* ((root (expand-file-name "orig/" tmp)) (copy-dir (expand-file-name "copy/" tmp))
          (other (expand-file-name "other/" tmp)))
     (dolist (d (list root copy-dir other)) (make-directory d t))
     (let ((orig (my-wt-register root)))
       (my-wt-write (lambda (db) (sqlite-execute db "INSERT INTO working_copies(copy_id,project_id,role,directory,owned,state,created_at)
                                                     VALUES ('c1',?,'copy',?,1,'ready','2026')" (list (plist-get orig :project_id) copy-dir))))
       (my-wt-register other)
       (my-pi-history-register "in-orig" root)
       (my-pi-history-register "in-copy" copy-dir)
       (my-pi-history-register "elsewhere" other)
       (my-pi-history-update "in-copy" :title "copy needle")
       (my-pi-history-update "elsewhere" :title "copy needle too")
       (should (equal (sort (mapcar (lambda (c) (plist-get c :id)) (my-pi-history-list root)) #'string<) '("in-copy" "in-orig")))
       (should (equal (mapcar (lambda (c) (plist-get c :id)) (my-pi-history-query root "needle")) '("in-copy")))
       (should (equal (mapcar (lambda (c) (plist-get c :id)) (my-pi-history-query copy-dir "needle")) '("in-copy")))
       (my-wt-update "c1" :state "deleted")
       (delete-directory copy-dir)
       (sqlite-close my-pi-history-db) (setq my-pi-history-db nil) ; a restart
       (should (equal (mapcar (lambda (c) (plist-get c :id)) (my-pi-history-query root "needle")) '("in-copy")))
       (should (my-pi-history-same-project-p root copy-dir))
       (should-not (my-pi-history-same-project-p root other))
       (should-error (my-pi-history-delete-finish other "in-copy"))
       (should-error (my-wt-register copy-dir) :type 'user-error)))))

(ert-deftest my-wt-worker-discovers-every-copy-and-keeps-metadata ()
  (my-wt-test
   (let* ((root (expand-file-name "orig/" tmp)) (copy-dir (expand-file-name "copy/" tmp))
          (sessions (expand-file-name "sessions/" tmp))
          (profile (list :map (expand-file-name "absent" tmp) :sessions sessions))
          (file (expand-file-name "c.jsonl" sessions)))
     (dolist (d (list root copy-dir sessions)) (make-directory d t))
     (let ((orig (my-wt-register root)))
       (my-wt-write (lambda (db) (sqlite-execute db "INSERT INTO working_copies(copy_id,project_id,role,directory,owned,created_at)
                                                     VALUES ('c1',?,'copy',?,1,'2026')" (list (plist-get orig :project_id) copy-dir))))
       (pi-test-jsonl file (list `((type . "session") (id . "s1") (cwd . ,copy-dir))
                                 (pi-test-message "u" nil "user" "copy question")))
       (should-not (my-pi-history-discover root profile))
       (should (equal (plist-get (my-pi-history-get "s1") :project_root) copy-dir))
       (my-pi-history-update "s1" :branch "feature/x" :revision "abc")
       (pi-test-jsonl file (list `((type . "session") (id . "s1") (cwd . ,copy-dir))
                                 (pi-test-message "u" nil "user" "copy question")
                                 (pi-test-message "r" "u" "assistant" "answer")))
       (set-file-times file (time-add nil 5))
       (my-pi-history-discover root profile)
       (should (equal (plist-get (my-pi-history-get "s1") :branch) "feature/x"))
       (should (equal (plist-get (my-pi-history-get "s1") :last_reply_id) "r"))
       (should (equal (plist-get (my-wt-copy "c1") :project_id) (plist-get orig :project_id)))))))

(ert-deftest my-wt-filter-is-literal-substring ()
  (let ((names (append '("CLOUD-1-request-id" "feature/Request" "a[b].c" "main" "trunk" "aXbYc")
                       (mapcar (lambda (i) (format "bulk-%02d" i)) (number-sequence 1 40)))))
    (should (equal (car (my-wt-filter "request" names)) '("CLOUD-1-request-id" "feature/Request")))
    (should (equal (car (my-wt-filter "[b]." names)) '("a[b].c")))
    (should-not (car (my-wt-filter "a.b" names)))
    (should-not (car (my-wt-filter "a.*c" names)))
    (should-not (car (my-wt-filter "" names)))
    (should-not (car (my-wt-filter "   " names)))
    (should (= (length (car (my-wt-filter "bulk" names))) 30))
    (should (cdr (my-wt-filter "bulk" names)))
    (should-not (cdr (my-wt-filter "bulk-1" names)))
    (should-not (string-search "/" (my-wt-slug "users/me/feature")))
    (should (equal (my-wt-slug "../..") "copy"))))

;;; Git lifecycle

(ert-deftest my-wt-rejects-explicit-branch-creation ()
  (dolist (vcs '("git" "arc"))
    (cl-letf (((symbol-function 'my-wt-call) (lambda (&rest _) (ert-fail "No VCS call expected"))))
      (should-error (my-wt-plan (list :vcs vcs :state "ready")
                               '(:branch "missing" :new t :start "HEAD")) :type 'user-error))))

(ert-deftest my-wt-picker-offers-no-branch-creation ()
  (with-temp-buffer
    (let ((my-wt-picker-start (make-string 40 ?a))
          (my-wt-picker-branches '(("existing" :local t))))
      (cl-letf (((symbol-function 'my-wt-picker-source) (lambda () '(:branch "existing")))
                ((symbol-function 'my-wt-label) (lambda (_) "existing")))
        (my-wt-picker-render-branches "existing"))
      (should (string-search "existing" (buffer-string)))
      (should-not (string-search "New branch" (buffer-string))))))

(ert-deftest my-wt-git-create-and-remove-leaves-source-unchanged ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (source (my-wt-register (expand-file-name "sub/" repo)))
          (head (my-wt-test-git repo "rev-parse" "HEAD")))
     (my-wt-test-git repo "branch" "existing")
     (with-temp-file (expand-file-name "sub/a.txt" repo) (insert "dirty source\n"))
     (let ((status (my-wt-test-git repo "status" "--porcelain"))
           (copy (my-wt-test-git-copy source "CLOUD-7/new")))
       (should (equal (plist-get copy :state) "ready"))
       (should (string-prefix-p (my-wt-base) (plist-get copy :vcs_root)))
       (should (equal (plist-get copy :directory) (expand-file-name "sub/" (plist-get copy :vcs_root))))
       (should-not (string-search "CLOUD-7/" (plist-get copy :vcs_root)))
       (should (equal (my-wt-test-git (plist-get copy :directory) "symbolic-ref" "--short" "HEAD") "CLOUD-7/new"))
       ;; Uncommitted source edits are not copied.
       (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "a.txt" (plist-get copy :directory))) (buffer-string)) "a\n"))
       (should (equal (my-wt-test-git repo "status" "--porcelain") status))
       (should (equal (my-wt-test-git repo "rev-parse" "HEAD") head))
       (should (equal (my-wt-test-git repo "symbolic-ref" "--short" "HEAD") "main"))
       (let ((existing (my-wt-test-create source (list :branch "existing"))))
         (should (equal (my-wt-test-git (plist-get existing :directory) "symbolic-ref" "--short" "HEAD") "existing"))
         ;; Asking again offers the registered copy instead of a second checkout.
         (should (equal (plist-get (plist-get (my-wt-create source (list :branch "existing")) :occupied) :copy_id)
                        (plist-get existing :copy_id))))
       (let (done)
         (my-wt-delete copy (lambda (error) (setq done (or error 'ok))))
         (my-wt-test-wait (lambda () done))
         (should (eq done 'ok)))
       (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "deleted"))
       (should-not (file-exists-p (plist-get copy :vcs_root)))
       (should (my-wt-test-git repo "rev-parse" "--verify" "CLOUD-7/new")) ; the branch survives
       (should (equal (my-wt-test-git repo "status" "--porcelain") status))))))

(ert-deftest my-wt-git-rejects-invalid-occupied-and-unsafe ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (source (my-wt-register repo))
          (head (my-wt-test-git repo "rev-parse" "HEAD")))
     (should-error (my-wt-create source (list :branch "bad..name")) :type 'user-error)
     (should-error (my-wt-create source (list :branch "main" :new t :start head)) :type 'user-error)
     (my-wt-test-git repo "worktree" "add" "-q" "-b" "outside" (expand-file-name "external" tmp))
     (should-error (my-wt-create source (list :branch "outside")) :type 'user-error)
     (should (member (my-wt-original (plist-get source :project_id)) (list (my-wt-original (plist-get source :project_id)))))
     (should (my-wt-delete-blockers source))
     (should-error (my-wt-delete source) :type 'user-error)
     (let ((copy (my-wt-test-git-copy source "work")))
       (dolist (name '("untracked.txt" "build.log"))
         (with-temp-file (expand-file-name name (plist-get copy :directory)) (insert "user data\n"))
         (let (done)
           (my-wt-delete (my-wt-copy (plist-get copy :copy_id)) (lambda (error) (setq done (or error 'ok))))
           (my-wt-test-wait (lambda () done))
           (should (stringp done))
           (should (file-exists-p (expand-file-name name (plist-get copy :directory))))
           (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "ready"))
           (delete-file (expand-file-name name (plist-get copy :directory)))))
       (let ((buffer (find-file-noselect (expand-file-name "sub/a.txt" (plist-get copy :directory)))))
         (with-current-buffer buffer (insert "unsaved"))
         (should-error (my-wt-delete (my-wt-copy (plist-get copy :copy_id))) :type 'user-error)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))))))

(ert-deftest my-wt-git-failure-is-recoverable-without-duplicates ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (source (my-wt-register repo))
          (copy (cl-letf (((symbol-function 'my-wt-run)
                          (lambda (_dir _program _args callback) (funcall callback 1 "" "temporary failure"))))
                  (my-wt-test-git-copy source "late"))))
     (should (equal (plist-get copy :state) "failed"))
     (should (plist-get copy :error))
     ;; A deleted local branch must not be recreated from a remote on retry.
     (my-wt-test-git repo "update-ref" "refs/remotes/origin/late" "HEAD")
     (my-wt-test-git repo "branch" "-D" "late")
     (should-error (my-wt-create source '(:branch "origin/late" :remote t)) :type 'user-error)
     (my-wt-retry copy)
     (my-wt-test-wait (lambda () (not (gethash (plist-get copy :copy_id) my-wt-busy))))
     (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "failed"))
     (should-not (zerop (car (my-wt-call repo "git" "show-ref" "--verify" "refs/heads/late"))))
     (should-not (file-exists-p (plist-get copy :vcs_root)))
     ;; The user can prepare the branch separately and retry the same copy.
     (my-wt-test-git repo "branch" "late")
     (my-wt-update (plist-get copy :copy_id) :start_revision (my-wt-test-git repo "rev-parse" "HEAD"))
     (my-wt-retry (my-wt-copy (plist-get copy :copy_id)))
     (my-wt-test-wait (lambda () (not (gethash (plist-get copy :copy_id) my-wt-busy))))
     (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "ready"))
     (should (= (length (my-wt-copies (plist-get source :project_id))) 2))
     ;; Emacs exiting mid-operation leaves records that are reconciled on startup.
     (my-wt-update (plist-get copy :copy_id) :state "creating")
     (my-wt-reconcile (plist-get source :project_id))
     (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "failed"))
     (my-wt-update (plist-get copy :copy_id) :state "deleting")
     (my-wt-reconcile (plist-get source :project_id))
     (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "ready"))
     (should (file-directory-p (plist-get copy :directory))))))

;;; Arc lifecycle with mocked commands

(ert-deftest my-wt-git-never-guesses-a-branch-deleted-after-preflight ()
  (dolist (phase '(add switch))
    (my-wt-test
     (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
            (source (my-wt-register repo))
            (run (symbol-function 'my-wt-run)) copy)
       (my-wt-test-git repo "branch" "side")
       (my-wt-test-git repo "config" "remote.origin.url" repo)
       (my-wt-test-git repo "config" "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*")
       (my-wt-test-git repo "update-ref" "refs/remotes/origin/side" "HEAD")
       (cl-letf (((symbol-function 'my-wt-run)
                  (lambda (dir program args callback)
                    (when (if (eq phase 'add)
                              (equal (seq-take args 2) '("worktree" "add"))
                            (equal (car args) "switch"))
                      (my-wt-test-git repo "branch" "-D" "side"))
                    (funcall run dir program args callback))))
         (setq copy (my-wt-test-create source '(:branch "side"))))
       (should (equal (plist-get copy :state) "failed"))
       (should-not (zerop (car (my-wt-call repo "git" "show-ref" "--verify" "refs/heads/side"))))
       (if (eq phase 'add)
           (should-not (file-exists-p (plist-get copy :vcs_root)))
         ;; A failed switch leaves a registered detached copy; retry must reuse it.
         (should (file-exists-p (plist-get copy :vcs_root))))
       (my-wt-test-git repo "branch" "side")
       (my-wt-retry copy)
       (my-wt-test-wait (lambda () (not (gethash (plist-get copy :copy_id) my-wt-busy))))
       (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "ready"))
       (should (equal (my-wt-test-git (plist-get copy :vcs_root) "symbolic-ref" "--short" "HEAD") "side"))))))

(defmacro my-wt-test-arc (responses &rest body)
  "Run BODY with Arc commands answered from RESPONSES, an alist of (ARGS-PREFIX . FUNCTION).
Each FUNCTION gets the directory and returns (STATUS STDOUT)."
  `(let ((arc-log nil))
     (cl-letf (((symbol-function 'my-wt-run)
                (lambda (directory program args callback)
                  (if (not (equal program (my-wt-arc)))
                      (funcall callback 1 "" "unexpected program")
                    (push (cons directory args) arc-log)
                    (let ((handler (cdr (cl-find-if (lambda (r) (equal (car r) (seq-take args (length (car r))))) ,responses))))
                      (pcase-let ((`(,status ,out) (if handler (funcall handler directory args) '(1 "unmocked"))))
                        (funcall callback status out (if (zerop status) "" out)))))))
               ((symbol-function 'my-wt-call)
                (lambda (directory _program &rest args)
                  (let ((handler (cdr (cl-find-if (lambda (r) (equal (car r) (seq-take args (length (car r))))) ,responses))))
                    (cond (handler (pcase-let ((`(,status ,out) (funcall handler directory args))) (cons status out)))
                          ((equal args '("rev-parse" "HEAD")) (cons 0 (concat (my-wt-test-sha ?a) "\n")))
                          (t (cons 1 "")))))))
       ,@body)))

(defun my-wt-test-sha (char) (make-string 40 char))

(defun my-wt-test-branches (&rest specs)
  "Arc `branch --all -vv --json' output; each spec is (NAME COMMIT LOCAL [REMOTE])."
  (json-serialize
   (vconcat (mapcar (lambda (spec)
                      (pcase-let ((`(,name ,commit ,local ,remote) spec))
                        (append `((name . ,name) (commit . ((id . ,commit))))
                                (when local '((local . t)))
                                (when remote `((remote . ,remote))))))
                    specs))))

(defun my-wt-test-arc-source (tmp)
  (let ((mount (expand-file-name "mount/" tmp)))
    (make-directory (expand-file-name ".arc" mount) t)
    (make-directory (expand-file-name "cloud/compute" mount) t)
    (with-temp-file (expand-file-name ".arc/HEAD" mount))
    (my-wt-register (expand-file-name "cloud/compute/" mount))))

(defun my-wt-test-mounts (source &optional new-store shared)
  (json-serialize
   (vconcat (list `((mount . ,(directory-file-name (plist-get source :vcs_root))) (status . "mounted") (store . "/s/orig") (object-store . "/s/orig/o") (tenant . "cloudia")))
            (when new-store
              (list `((mount . ,(directory-file-name new-store)) (status . "mounted") (store . ,(if shared "/s/orig" "/s/new"))
                      (object-store . ,(if shared "/s/orig/o" "/s/new/o")) (tenant . "cloudia")))))))





(defun my-wt-test-arc-copy (source root)
  "Register an application-owned Arc copy mounted at ROOT, started at sha a."
  (make-directory (expand-file-name "cloud/compute" root) t)
  (my-wt-write (lambda (db) (sqlite-execute db "INSERT INTO working_copies(copy_id,project_id,role,directory,vcs_root,relative_path,vcs,
                  arc_store,arc_object_store,owned,state,tree_name,branch,start_revision,created_at)
                  VALUES ('ac',?,'copy',?,?,'cloud/compute/','arc','/s/new','/s/new/o',1,'ready','t','CLOUD-9',?,'2026')"
                                            (list (plist-get source :project_id) (expand-file-name "cloud/compute/" root) root
                                                  (my-wt-test-sha ?a))))))

(defun my-wt-test-arc-delete-responses (source root state)
  "Mocked Arc answers for deleting the copy at ROOT; STATE is a plist of overrides."
  (list (cons '("worktree" "list") (lambda (&rest _) (list 0 (my-wt-test-mounts source root))))
        (cons '("info") (lambda (&rest _) (list 0 (plist-get (car state) :info))))
        (cons '("status") (lambda (&rest _) '(0 "{\"status\":{}}")))
        (cons '("stash") (lambda (&rest _) '(0 "")))
        (cons '("branch" "--list") (lambda (&rest _) (list 0 (plist-get (car state) :branches))))
        (cons '("merge-base") (lambda (&rest _) (list 0 (plist-get (car state) :merge-base))))
        (cons '("unmount") (lambda (dir _) (should-not (file-in-directory-p dir root)) (plist-get (car state) :unmount)))))

(defun my-wt-test-delete-result (copy)
  (let (done)
    (my-wt-delete copy (lambda (e) (setq done (or e 'ok))))
    (my-wt-test-wait (lambda () done))
    done))

(ert-deftest my-wt-release-restores-windows-after-temporary-output ()
  (my-wt-test
   (let* ((root (expand-file-name "copy/" tmp))
          (copy (list :vcs_root root :directory root))
          (file (find-file-noselect (expand-file-name "main.go" tmp)))
          (other (find-file-noselect (expand-file-name "other.go" tmp))))
     (make-directory root t)
     (switch-to-buffer file)
     (let ((editor (selected-window))
           (second (split-window-below)))
       (set-window-buffer second other)
       (dolist (reuse '(nil t))
         (let ((output (generate-new-buffer "*wt-release-output*")))
           (unwind-protect
               (progn
                 (with-current-buffer output
                   (setq default-directory root)
                   (special-mode))
                 (if reuse
                     (with-selected-window second
                       (display-buffer output '(display-buffer-same-window)))
                   (let ((split-height-threshold 0))
                     (display-buffer output '(display-buffer-pop-up-window))))
                 (should (get-buffer-window output))
                 (should (= (length (window-list)) (if reuse 2 3)))
                 (my-wt-release copy)
                 (should-not (buffer-live-p output))
                 (should (= (length (window-list)) 2))
                 (should (eq (window-buffer editor) file))
                 (should (eq (window-buffer second) other))
                 (should (eq (selected-window) editor)))
             (when (buffer-live-p output) (kill-buffer output)))))))))

(ert-deftest my-wt-release-stops-only-own-eglot-before-killing-buffers ()
  (my-wt-test
   (require 'eglot)
   (let* ((root (expand-file-name "copy/" tmp))
          (buffer (generate-new-buffer " *wt-release*"))
          (servers (make-hash-table :test #'equal)) events)
     (make-directory root t)
     (puthash (cons 'transient root) '(own-server) servers)
     (puthash (cons 'transient tmp) '(other-server) servers)
     (unwind-protect
         (cl-progv '(eglot--servers-by-project) (list servers)
           (cl-letf (((symbol-function 'my-wt-copy-buffers) (lambda (_) (list buffer)))
                     ((symbol-function 'eglot-shutdown) (lambda (server) (push server events))))
             (with-current-buffer buffer
               (add-hook 'kill-buffer-hook (lambda () (push 'kill events)) nil t))
             (cl-letf (((symbol-function 'eglot-shutdown) (lambda (_) (error "Shutdown failed"))))
               (should-error (my-wt-release (list :vcs_root root :directory root)))
               (should (buffer-live-p buffer))
               (should-not events))
             (my-wt-release (list :vcs_root root :directory root))
             (should (equal (reverse events) '(own-server kill)))))
       (when (buffer-live-p buffer) (kill-buffer buffer))))))







(ert-deftest my-wt-arc-availability-needs-the-recorded-mount ()
  (my-wt-test
   (let* ((source (my-wt-test-arc-source tmp))
          (root (file-name-as-directory (expand-file-name "copy-mount" tmp)))
          (mounted nil) (store "/s/new"))
     (my-wt-test-arc-copy source root)
     (my-wt-test-arc
      (list (cons '("worktree" "list")
                  (lambda (&rest _)
                    (list 0 (json-serialize
                             (vconcat (list `((mount . ,(directory-file-name (plist-get source :vcs_root))) (status . "mounted") (store . "/s/orig")))
                                      (when mounted (list `((mount . ,(directory-file-name root)) (status . "mounted") (store . ,store))))))))))
      ;; The empty mount-point directory still exists after unmounting.
      (should (file-directory-p (plist-get (my-wt-copy "ac") :directory)))
      (my-wt-reconcile (plist-get source :project_id))
      (should (equal (plist-get (my-wt-copy "ac") :state) "unavailable"))
      (should-not (my-wt-usable-p (my-wt-copy "ac")))
      ;; A remount with another store is not the recorded copy.
      (make-directory (expand-file-name ".arc" root) t)
      (with-temp-file (expand-file-name ".arc/HEAD" root))
      (setq mounted t store "/s/other" my-wt-arc-mounts-cache nil)
      (my-wt-reconcile (plist-get source :project_id))
      (should (equal (plist-get (my-wt-copy "ac") :state) "unavailable"))
      (setq store "/s/new" my-wt-arc-mounts-cache nil)
      (my-wt-reconcile (plist-get source :project_id))
      (should (equal (plist-get (my-wt-copy "ac") :state) "ready"))
      ;; The original is adopted with the store Arc reports for it.
      (should (my-wt-usable-p (my-wt-original (plist-get source :project_id))))
      (should (equal (plist-get (my-wt-original (plist-get source :project_id)) :arc_store) "/s/orig"))))))

;;; Editor state

(ert-deftest my-wt-switch-keeps-buffers-distinct-and-alive ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (root (expand-file-name "sub/" repo)))
     (my-project-open root)
     (let* ((source (my-wt-tab-copy))
            (copy (my-wt-test-git-copy source "side"))
            (original-file (find-file (expand-file-name "a.txt" root))))
       (insert "unsaved original edit ")
       (my-wt-switch copy)
       (should (= (length (tab-bar-tabs)) 2))
       (should (equal (alist-get 'my-project-root (tab-bar--current-tab)) (plist-get copy :directory)))
       (should (buffer-live-p original-file))
       (should (buffer-modified-p original-file))
       (should-not (memq original-file (my-project-file-tabs)))
       (let ((copy-file (find-file (expand-file-name "a.txt" (plist-get copy :directory)))))
         (should-not (eq copy-file original-file))
         (should (equal (buffer-file-name original-file) (expand-file-name "a.txt" root)))
         (should (equal (project-root (project-current nil (plist-get copy :directory))) (plist-get copy :directory)))
         (with-current-buffer copy-file
           (should (equal (project-root (project-current)) (plist-get copy :directory))))
         (should (equal (mapcar #'treemacs-project->path (treemacs-workspace->projects (treemacs-current-workspace)))
                        (list (directory-file-name (plist-get copy :directory)))))
         ;; Opening the original folder again returns to the same tab and its state.
         (my-project-open root)
         (should (= (length (tab-bar-tabs)) 2))
         (should (eq (current-buffer) original-file))
         (should (memq original-file (my-project-file-tabs)))
         (should-not (memq copy-file (my-project-file-tabs)))
         (should (equal (plist-get (my-wt-project (plist-get copy :project_id)) :active) (plist-get source :copy_id)))
         ;; The session map records the active copy; inactive copies persist their files.
         (my-project-session-roots)
         (should (equal (caar tabspaces-project-tab-map) root))
         (should (member (expand-file-name "a.txt" (plist-get copy :directory))
                         (with-temp-buffer (insert-file-contents (my-project-files-state-file (plist-get copy :directory)))
                                           (read (current-buffer)))))
         (with-current-buffer original-file (set-buffer-modified-p nil)))))))

(ert-deftest my-wt-missing-files-are-not-recreated ()
  (my-wt-test
   (let* ((root (expand-file-name "p/" tmp)) (kept (expand-file-name "kept.txt" root))
          (gone (expand-file-name "gone.txt" root)))
     (make-directory root t)
     (with-temp-file kept (insert "x"))
     (make-directory (file-name-directory (my-project-files-state-file root)) t)
     (with-temp-file (my-project-files-state-file root) (prin1 (list gone kept) (current-buffer)))
     (my-project-open root)
     (should (get-file-buffer kept))
     (should-not (get-file-buffer gone))
     (should-not (my-project-skip-missing-file (lambda (_) (error "must not visit")) gone))
     (let ((buffer (find-file-noselect kept)))
       (with-current-buffer buffer (insert "edit"))
       (delete-file kept)
       (my-wt-report-missing root)
       (should (buffer-live-p buffer))
       (should (buffer-modified-p buffer))
       (should-not (file-exists-p kept))
       (with-current-buffer buffer (set-buffer-modified-p nil))))))

(ert-deftest my-wt-header-shows-branch-and-plus ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp))))
     (my-project-open repo)
     (let ((copy (my-wt-tab-copy)) done)
       (my-wt-refresh-branch copy (lambda (_) (setq done t)))
       (my-wt-test-wait (lambda () done))
       (let ((header (my-wt-header)))
         (should (string-prefix-p " ⌂ main" header))
         (should (string-suffix-p " + " header)))
       ;; A late answer for a superseded request does not overwrite the label.
       (puthash (plist-get copy :directory) 99 my-wt-generations)
       (my-wt-test-git repo "checkout" "-q" "-b" "moved")
       (setq done nil)
       (my-wt-refresh-branch copy (lambda (_) (setq done t)))
       (puthash (plist-get copy :directory) 1000 my-wt-generations)
       (let ((deadline (+ (float-time) 2))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
       (should-not done)
       (should (string-prefix-p " ⌂ main" (my-wt-header)))))))

(ert-deftest my-wt-generated-copies-are-not-project-files ()
  (my-wt-test
   (let ((generated (expand-file-name "worktree/git/p-1/t/x.txt" user-emacs-directory))
         (own (expand-file-name "init.el" user-emacs-directory)))
     (make-directory (file-name-directory generated) t)
     (with-temp-file generated) (with-temp-file own)
     (let* ((source (my-project-search-source user-emacs-directory)) (default-directory (car source)))
       (with-temp-buffer
         (should (zerop (apply #'call-process (cadr source) nil t nil (cddr source))))
         (should (string-search "init.el" (buffer-string)))
         (should-not (string-search "x.txt" (buffer-string)))))
     ;; Inside a copy, its own files are listed.
     (let* ((source (my-project-search-source (file-name-directory generated))) (default-directory (car source)))
       (with-temp-buffer
         (apply #'call-process (cadr source) nil t nil (cddr source))
         (should (string-search "x.txt" (buffer-string))))))))

(ert-deftest my-wt-reload-migrates-open-connection ()
  (my-wt-test
   (let ((root (expand-file-name "one/" tmp)) (other (expand-file-name "two/" tmp)))
     (my-wt-test-v1-db root other)
     ;; A running Emacs holds a connection opened by the previous configuration.
     (setq my-pi-history-db (sqlite-open (my-pi-history-path)))
     (load (expand-file-name "pi-history.el" my-wt-test-config) nil t)
     (should (= (caar (sqlite-select my-pi-history-db "PRAGMA user_version")) 3))
     (should (equal (mapcar (lambda (c) (plist-get c :id)) (my-pi-history-list root)) '("a"))))))

(defun my-wt-test-tab-files ()
  (sort (mapcar #'buffer-file-name (my-project-file-tabs)) #'string<))

(ert-deftest my-wt-close-reopen-keeps-copy-files-separate ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (root (expand-file-name "sub/" repo)))
     (my-project-open root)
     (let* ((source (my-wt-tab-copy))
            (copy (my-wt-test-git-copy source "side"))
            (original-file (expand-file-name "a.txt" root))
            (copy-file (expand-file-name "a.txt" (plist-get copy :directory))))
       (find-file original-file)
       (my-wt-switch copy)
       (find-file copy-file)
       (tab-bar-close-tab)
       (should-not (get-file-buffer original-file))
       (should-not (get-file-buffer copy-file))
       (my-project-open (plist-get copy :directory))
       (should (equal (my-wt-test-tab-files) (list copy-file)))
       (my-wt-switch source)
       (should (equal (my-wt-test-tab-files) (list original-file)))
       (should (= (length (tab-bar-tabs)) 2))))))

(ert-deftest my-wt-canceled-close-keeps-inactive-copy-state ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (root (expand-file-name "sub/" repo)))
     (my-project-open root)
     (let* ((source (my-wt-tab-copy))
            (copy (my-wt-test-git-copy source "side"))
            (original (find-file (expand-file-name "a.txt" root))))
       (insert "unsaved original edit")
       (my-wt-switch copy)
       (find-file (expand-file-name "a.txt" (plist-get copy :directory)))
       ;; Declining to kill the unsaved buffer cancels the whole close.
       (cl-letf (((symbol-function 'save-some-buffers) #'ignore)
                 ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
         (should-error (tab-bar-close-tab) :type 'user-error))
       (should (= (length (tab-bar-tabs)) 2))
       (should (gethash root my-wt-states))
       (should (buffer-live-p original))
       (should (buffer-modified-p original))
       (my-wt-switch source)
       (should (eq (current-buffer) original))
       (with-current-buffer original (set-buffer-modified-p nil))))))

(ert-deftest my-wt-git-context-has-commit-ids ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (copy (my-wt-register repo)) (sha (my-wt-test-git repo "rev-parse" "HEAD")) result)
     (my-wt-refresh-branch copy (lambda (info) (setq result info)))
     (my-wt-test-wait (lambda () result))
     (should (equal result (list :branch "main" :revision sha)))
     (should (equal (my-wt-context-now copy) (list :branch "main" :revision sha)))
     (my-wt-test-git repo "checkout" "-q" "--detach")
     (setq result nil)
     (my-wt-refresh-branch copy (lambda (info) (setq result info)))
     (my-wt-test-wait (lambda () result))
     (should (equal result (list :branch nil :revision sha)))
     (should (equal (my-wt-label copy) (format "detached@%.7s" sha)))
     (should (equal (my-wt-context-now copy) (list :branch nil :revision sha))))))

;;; Arc preparation honours the captured revision

(ert-deftest my-wt-copy-access-migrates-existing-v2-catalogue ()
  (my-wt-test
   (let* ((copy (my-wt-register tmp)) (id (plist-get copy :copy_id))
          (db (my-pi-history-open)))
     (my-pi-history-register "existing-chat" tmp)
     (sqlite-execute db "ALTER TABLE working_copies DROP COLUMN last_opened_at")
     (my-pi-history-migrate db)
     (my-pi-history-migrate db)
     (should (equal (plist-get (my-wt-copy id) :directory) tmp))
     (should (my-pi-history-get "existing-chat"))
     (should-not (plist-get (my-wt-copy id) :last_opened_at))
     (should (= (length (directory-files (expand-file-name "pi/backups/" user-emacs-directory) nil "\\.sqlite\\'")) 1)))))

(ert-deftest my-wt-picker-lists-all-copies-original-then-access-order ()
  (my-wt-test
   (let* ((original (my-wt-register tmp)) (project (plist-get original :project_id)))
     (dotimes (i 35)
       (sqlite-execute (my-pi-history-open)
                       "INSERT INTO working_copies(copy_id,project_id,role,directory,branch,created_at)
                        VALUES (?,?,'copy',?,?,?)"
                       (list (format "c%02d" i) project (expand-file-name (format "c%02d/" i) tmp)
                             (format "branch%02d" i) (format "2026-01-%02d" (1+ i)))))
     (cl-letf (((symbol-function 'my-pi-history-now) (lambda () "2026-02-01")))
       (my-wt-set-active (my-wt-copy "c03")))
     (cl-letf (((symbol-function 'my-pi-history-now) (lambda () "2026-02-02")))
       (my-wt-set-active (my-wt-copy "c01")))
     ;; Lifecycle changes and session restoration must not affect access order.
     (my-wt-update "c03" :state "unavailable")
     (my-wt-set-active (my-wt-copy "c03") t)
     (my-wt-update "c34" :state "deleted")
     (sqlite-close my-pi-history-db) (setq my-pi-history-db nil)
     (with-temp-buffer
       (my-wt-picker-mode)
       (setq my-wt-picker-project project default-directory tmp)
       (my-wt-picker-render)
       (should-not my-wt-picker-input-start)
       (should-not (string-search "Search:" (buffer-string)))
       (let ((pos (point-min)) labels)
         (while (setq pos (next-button pos))
           (push (button-label pos) labels))
         (setq labels (nreverse labels))
         (should (equal (seq-take labels 3) (list (my-wt-label original) "branch01" "branch03")))
         (should (= (length labels) 36)) ; original + 34 copies + New working copy
         (should-not (member "branch34" labels))
         (should (member "branch00" labels)))))))

(defun my-wt-test-arc-prepare (source state)
  "Mocked Arc for creating a copy; STATE is a one-element list holding a plist:
:branches (fresh store's -vv list), :head (branch . commit) after checkout."
  (list (cons '("worktree" "list") (lambda (&rest _) (list 0 (my-wt-test-mounts source (plist-get (car state) :mounted)))))
        (cons '("mount" "--repository")
              (lambda (_dir args) (let ((root (car (last args))))
                                    (setf (car state) (plist-put (car state) :mounted root))
                                    (make-directory (expand-file-name "cloud/compute" root) t))
                '(0 "")))
        (cons '("branch" "--list" "--all")
              (lambda (&rest _) (list 0 (or (plist-get (car state) :source-branches) (plist-get (car state) :branches)))))
        (cons '("branch" "--list") (lambda (&rest _) (list 0 (plist-get (car state) :branches))))
        (cons '("log") (lambda (&rest _) '(0 "[]")))
        (cons '("checkout") (lambda (_dir args)
                              (setf (car state) (plist-put (car state) :head
                                                           (if (equal (cadr args) "-b") (cons (nth 2 args) (nth 3 args))
                                                             (cons (cadr args) (plist-get (car state) :existing)))))
                              '(0 "")))
        (cons '("info") (lambda (&rest _)
                          (let ((head (plist-get (car state) :head)))
                            (list 0 (json-serialize `((branch . ,(car head)) (hash . ,(cdr head))))))))))

(defun my-wt-test-checkouts (arc-log)
  (mapcar #'cdr (cl-remove-if-not (lambda (e) (equal (cadr e) "checkout")) arc-log)))

(ert-deftest my-wt-arc-missing-source-branch-fails-before-creating-copy ()
  (my-wt-test
   (let* ((source (my-wt-test-arc-source tmp))
          (before (my-wt-copies (plist-get source :project_id))))
     (dolist (response '((0 "[]") (1 "daemon unavailable") (0 "invalid JSON")))
       (my-wt-test-arc
        (list (cons '("branch" "--list") (lambda (&rest _) response)))
        (should-error (my-wt-create source (list :branch "missing" :sha (my-wt-test-sha ?a))) :type 'user-error)
        (should (equal before (my-wt-copies (plist-get source :project_id))))
        (should-not arc-log)
        (should-not (file-exists-p (my-wt-base))))))))











(load (expand-file-name "worktrees-native-arc-tests.el" (file-name-directory load-file-name)) nil t)
