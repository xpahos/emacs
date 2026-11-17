;;; worktrees.el --- Git worktrees and Arc mounts as project working copies -*- lexical-binding: t; -*-
;; A logical project groups an original directory and application-owned
;; copies.  Records live in the Pi catalogue so history can span all copies.
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(load (expand-file-name "pi-history.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defvar my-wt-states (make-hash-table :test #'equal)
  "Copy directory -> saved editor state (WINDOW-CONFIG BUFFERS BURIED).")
(defvar my-wt-busy (make-hash-table :test #'equal)
  "Copy IDs with a lifecycle operation running in this Emacs.")
(defvar my-wt-branches (make-hash-table :test #'equal)
  "Copy directory -> live VCS info plist (:branch :revision :error).")
(defvar my-wt-generations (make-hash-table :test #'equal))
(defvar my-wt-change-hook nil "Run after copy records or branch labels change.")

(defun my-wt-base () (expand-file-name "worktree/" user-emacs-directory))
(defun my-wt-arc () (if (boundp 'arcit-arc-executable) arcit-arc-executable "arc"))
(defun my-wt-dir (directory) (file-name-as-directory (file-truename directory)))

;;; Registry

(defconst my-wt-columns
  '(copy_id project_id role directory vcs_root relative_path vcs arc_repository arc_store
    arc_object_store owned state tree_name branch start_revision error created_at updated_at last_opened_at source_copy_id arc_remote_ref))

(defun my-wt--row (row)
  (let (plist)
    (cl-mapc (lambda (key value) (setq plist (plist-put plist (intern (format ":%s" key)) value)))
             my-wt-columns row)
    plist))

(defun my-wt--select (where args)
  (mapcar #'my-wt--row
          (sqlite-select (my-pi-history-open)
                         (format "SELECT %s FROM working_copies %s"
                                 (mapconcat #'symbol-name my-wt-columns ",") where)
                         args)))

(defun my-wt-copy (id) (car (my-wt--select "WHERE copy_id=?" (list id))))
(defun my-wt-copy-at (directory)
  (and directory (car (my-wt--select "WHERE directory=?" (list (my-wt-dir directory))))))
(defun my-wt-copies (project-id)
  "Copies of PROJECT-ID, original first, then most recently opened."
  (my-wt--select "WHERE project_id=? ORDER BY role='original' DESC,
                 last_opened_at DESC, created_at DESC, copy_id" (list project-id)))
(defun my-wt-original (project-id)
  (car (my-wt--select "WHERE project_id=? AND role='original'" (list project-id))))
(defun my-wt-project (project-id)
  (when-let* ((row (car (sqlite-select (my-pi-history-open)
                         "SELECT project_id,name,active_copy_id,picker_width,picker_height,picker_left,picker_top
                          FROM logical_projects WHERE project_id=?" (list project-id)))))
    (cl-mapcan #'list '(:id :name :active :width :height :left :top) row)))

(defun my-wt-write (function)
  "Call FUNCTION in a transaction, waiting out short worker locks."
  (let ((db (my-pi-history-open)) (attempt 0) result done)
    (while (not done)
      (condition-case err
          (setq result (my-pi-history-transaction db (funcall function db)) done t)
        (sqlite-error
         (unless (and (< (cl-incf attempt) 60) (string-match-p "locked\\|busy" (error-message-string err)))
           (signal (car err) (cdr err)))
         (sleep-for 0.05))))
    (run-hooks 'my-wt-change-hook)
    result))

(defun my-wt-update (id &rest fields)
  (my-wt-write
   (lambda (db)
     (while fields
       (let ((key (intern (substring (symbol-name (pop fields)) 1))) (value (pop fields)))
         (unless (memq key (cddr my-wt-columns)) (error "Invalid copy field %s" key))
         (sqlite-execute db (format "UPDATE working_copies SET %s=?,updated_at=? WHERE copy_id=?" key)
                         (list value (my-pi-history-now) id)))))))

(defun my-wt-set-active (copy &optional restoring)
  "Select COPY, recording access unless RESTORING a saved session."
  (my-wt-write
   (lambda (db)
     (sqlite-execute db "UPDATE logical_projects SET active_copy_id=? WHERE project_id=?"
                     (list (plist-get copy :copy_id) (plist-get copy :project_id)))
     (unless restoring
       (sqlite-execute db "UPDATE working_copies SET last_opened_at=? WHERE copy_id=?"
                       (list (my-pi-history-now) (plist-get copy :copy_id)))))))

(defun my-wt-detect (directory)
  "Return (VCS . ROOT) for DIRECTORY from filesystem markers, without processes."
  (when-let* ((root (locate-dominating-file
                     directory (lambda (d) (or (file-exists-p (expand-file-name ".git" d))
                                               (file-exists-p (expand-file-name ".arc/HEAD" d)))))))
    (cons (if (file-exists-p (expand-file-name ".git" root)) "git" "arc") (my-wt-dir root))))

(defun my-wt-register (directory)
  "Resolve DIRECTORY to its working copy, registering a new project when unknown."
  (let* ((directory (my-wt-dir directory)) (copy (my-wt-copy-at directory)))
    (when (equal (plist-get copy :state) "deleted")
      (user-error "%s belonged to a deleted working copy of project %s; it is not reused"
                  directory (plist-get (my-wt-project (plist-get copy :project_id)) :name)))
    (unless (and copy (plist-get copy :vcs_root))
      (let ((vcs (my-wt-detect directory)))
        (my-wt-write
         (lambda (db)
           (my-pi-history--ensure-copy db directory)
           (when vcs
             (sqlite-execute db "UPDATE working_copies SET vcs=?,vcs_root=?,relative_path=? WHERE directory=? AND vcs_root IS NULL"
                             (list (car vcs) (cdr vcs) (file-relative-name directory (cdr vcs)) directory)))))
        (setq copy (my-wt-copy-at directory))))
    copy))

(defun my-wt-tab-copy (&optional tab)
  (my-wt-copy-at (alist-get 'my-project-root (or tab (tab-bar--current-tab)))))

;;; Processes

(defun my-wt-run (directory program args callback)
  "Run PROGRAM with ARGS in DIRECTORY; CALLBACK gets (STATUS STDOUT STDERR)."
  (let* ((default-directory (file-name-as-directory directory))
         (out (generate-new-buffer " *worktree*")) (err (generate-new-buffer " *worktree-err*")))
    (condition-case failure
        (let ((process (make-process
         :name "worktree" :buffer out :stderr err :noquery t :connection-type 'pipe
         :coding 'utf-8-unix :command (cons program args)
         :sentinel
         (lambda (process _event)
           (when (memq (process-status process) '(exit signal))
             (when-let* ((stderr (get-buffer-process err)))
               (while (accept-process-output stderr 0.01)))
             (let ((stdout (with-current-buffer out (buffer-string)))
                   (stderr (with-current-buffer err (string-trim (buffer-string)))))
               (kill-buffer out) (kill-buffer err)
               (funcall callback (process-exit-status process) stdout stderr)))))))
          (process-put process 'my-wt-releasable t)
          process)
      (error (kill-buffer out) (kill-buffer err)
             (funcall callback -1 "" (error-message-string failure))))))

(defun my-wt-call (directory program &rest args)
  "Run a quick PROGRAM synchronously in DIRECTORY; return (STATUS . STDOUT)."
  (let ((default-directory (file-name-as-directory directory)))
    (with-temp-buffer
      (cons (condition-case nil (apply #'call-process program nil (list t nil) nil args) (error -1))
            (buffer-string)))))

(defun my-wt-chain (steps done)
  "Run STEPS, completing once even when a step signals before calling NEXT."
  (if (not steps) (funcall done nil)
    (let (advanced)
      (condition-case failure
          (funcall (car steps)
                   (lambda (&optional error)
                     (unless advanced
                       (setq advanced t)
                       (if error (funcall done error) (my-wt-chain (cdr steps) done)))))
        ((error quit)
         (unless advanced
           (setq advanced t)
           (funcall done (error-message-string failure))))))))

(defun my-wt-step (directory program args &optional check)
  "A chain step; report validation errors and quit through NEXT."
  (lambda (next)
    (my-wt-run directory program args
      (lambda (status out err)
        (let ((failure (condition-case failure
                           (if (zerop status) (and check (funcall check out))
                             (format "%s %s failed: %s" (file-name-nondirectory program) (car args)
                                     (my-wt-clean-error (if (string-empty-p err) out err))))
                         ((error quit) (error-message-string failure)))))
          (funcall next failure))))))

(defun my-wt-clean-error (text)
  "Drop Arc's Full Disk Access banner from TEXT."
  (string-trim (replace-regexp-in-string
                "Warning: arc was started from an app without Full Disk Access\\.\\(?:.\\|\n\\)*?Privacy_AllFiles\"\n*" "" text)))

(defun my-wt-json (text)
  (json-parse-string (my-wt-clean-error text) :object-type 'plist :array-type 'list :null-object nil :false-object nil))

;;; Live branch information

(defun my-wt-refresh-branch (copy &optional callback)
  "Read COPY's branch asynchronously; results of superseded requests are dropped."
  (let* ((dir (plist-get copy :directory)) (generation (1+ (gethash dir my-wt-generations 0)))
         (finish (lambda (info)
                   (when (= generation (gethash dir my-wt-generations))
                     (puthash dir info my-wt-branches)
                     (run-hooks 'my-wt-change-hook)
                     (force-mode-line-update t)
                     (when callback (funcall callback info))))))
    (puthash dir generation my-wt-generations)
    (cond
     ((not (file-accessible-directory-p dir)) (funcall finish (list :error "unavailable")))
     ((equal (plist-get copy :vcs) "git")
      (my-wt-run dir "git" my-wt-git-context-args
        (lambda (status out _)
          (funcall finish (or (and (zerop status) (my-wt-git-context out)) (list :error "no branch"))))))
     ((equal (plist-get copy :vcs) "arc")
      (my-wt-run dir (my-wt-arc) '("info" "--json")
        (lambda (status out _)
          (funcall finish (or (and (zerop status)
                                   (ignore-errors
                                     (let ((info (my-wt-json out)))
                                       (list :branch (plist-get info :branch) :revision (plist-get info :hash)
                                             :remote-head (plist-get info :remote_head)
                                             :repository (plist-get info :repository)))))
                              (list :error "no branch"))))))
     (t (funcall finish (list :error "no VCS"))))))

(defun my-wt-label (copy)
  "Branch label for COPY from the last live read."
  (let ((info (gethash (plist-get copy :directory) my-wt-branches)))
    (cond ((plist-get info :branch))
          ((plist-get info :revision) (format "detached@%.7s" (plist-get info :revision)))
          ((plist-get info :error) (format "%s (%s)" (or (plist-get copy :tree_name) "original") (plist-get info :error)))
          ((plist-get copy :branch))
          (t "…"))))

(defconst my-wt-git-context-args '("rev-parse" "HEAD" "--abbrev-ref" "HEAD")
  "The commit ID, then the branch name (\"HEAD\" when detached).")

(defun my-wt-commit-id-p (text)
  (and (stringp text) (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" text)))

(defun my-wt-git-context (out)
  "Parse `my-wt-git-context-args' output into (:branch :revision); nil if malformed."
  (pcase (split-string out "\n" t)
    (`(,sha ,name) (when (my-wt-commit-id-p sha)
                     (list :branch (unless (equal name "HEAD") name) :revision sha)))))

(defun my-wt-context-now (copy)
  "COPY's branch and commit read synchronously, for decisions that must not use a stale label.
Return (:branch NAME-OR-NIL :revision SHA), nil when unknown; a nil branch means detached."
  (let ((dir (plist-get copy :directory)))
    (when (file-accessible-directory-p dir)
      (if (equal (plist-get copy :vcs) "git")
          (pcase (apply #'my-wt-call dir "git" my-wt-git-context-args) (`(0 . ,out) (my-wt-git-context out)))
        (pcase (my-wt-call dir (my-wt-arc) "info" "--json")
          (`(0 . ,out) (ignore-errors
                         (let ((info (my-wt-json out)))
                           (when (my-wt-commit-id-p (plist-get info :hash))
                             (list :branch (plist-get info :branch) :revision (plist-get info :hash)))))))))))

;;; Availability

(defvar my-wt-arc-mounts-cache nil "(TIME . ENTRIES) from the last `arc mount --list'.")

(defun my-wt-arc-mounts ()
  "Arc's mount list, reused for two seconds so one action costs one call."
  (unless (and my-wt-arc-mounts-cache (< (- (float-time) (car my-wt-arc-mounts-cache)) 2))
    (setq my-wt-arc-mounts-cache
          (cons (float-time)
                (pcase (my-wt-call user-emacs-directory (my-wt-arc) "worktree" "list" "--json" "--no-status")
                  (`(0 . ,out) (ignore-errors (my-wt-json out)))))))
  (cdr my-wt-arc-mounts-cache))

(defun my-wt-arc-mounted-p (copy)
  "Non-nil when COPY's root is a live Arc mount whose store matches the record.
An empty mount-point directory left after unmounting does not qualify."
  (let ((root (plist-get copy :vcs_root)))
    (when-let* (((file-exists-p (expand-file-name ".arc/HEAD" root)))
                (entry (my-wt-mount-entry (my-wt-arc-mounts) root))
                ((equal (plist-get entry :status) "mounted")))
      (cond ((null (plist-get copy :arc_store))
             ;; Originals are adopted as found, so a later remount can be compared.
             (my-wt-update (plist-get copy :copy_id) :arc_store (plist-get entry :store)
                           :arc_object_store (plist-get entry :object-store))
             t)
            ((equal (plist-get entry :store) (plist-get copy :arc_store)))))))

(defun my-wt-usable-p (copy)
  "Non-nil when COPY can host editing and agent work right now."
  (and (member (plist-get copy :state) '("ready" "unavailable"))
       (file-accessible-directory-p (plist-get copy :directory))
       (pcase (plist-get copy :vcs)
         ("arc" (my-wt-arc-mounted-p copy))
         ("git" (file-exists-p (expand-file-name ".git" (plist-get copy :vcs_root))))
         (_ t))))

;;; Names and layout

(defun my-wt-slug (text)
  "Filesystem-safe directory name for TEXT; `/' never nests directories."
  (let ((slug (replace-regexp-in-string "[^A-Za-z0-9._-]+" "-" text)))
    (setq slug (string-trim (replace-regexp-in-string "\\.\\.+" "." slug) "[-.]+" "[-.]+"))
    (truncate-string-to-width (if (string-empty-p slug) "copy" slug) 48)))

(defun my-wt-allocate (project vcs branch)
  "Return (TREE-NAME . ROOT) for a new copy, unique on disk and in the registry."
  (let ((parent (expand-file-name (format "%s/%s-%s/" vcs (my-wt-slug (plist-get project :name)) (plist-get project :id))
                                  (my-wt-base)))
        name root)
    (while (or (not root) (file-exists-p root) (my-wt--select "WHERE vcs_root=?" (list root)))
      (setq name (format "%s-%s" (my-wt-slug branch) (substring (my-pi-history-id) 0 4))
            root (file-name-as-directory (expand-file-name name parent))))
    (cons name root)))

;;; Branch listing

(defun my-wt-branches (copy callback)
  "Deliver (NAME . PLIST) branch candidates of COPY to CALLBACK asynchronously."
  (let ((dir (plist-get copy :directory)))
    (if (equal (plist-get copy :vcs) "git")
        (my-wt-run dir "git" '("for-each-ref" "--format=%(refname)%00%(objectname)" "refs/heads" "refs/remotes")
          (lambda (status out err)
            (funcall callback
                     (if (/= status 0) (list :error err)
                       (delq nil (mapcar (lambda (line)
                                           (pcase-let ((`(,ref ,sha) (split-string line "\0")))
                                             (cond ((string-prefix-p "refs/heads/" ref)
                                                    (list (substring ref 11) :sha sha :local t))
                                                   ((and (string-prefix-p "refs/remotes/" ref) (not (string-suffix-p "/HEAD" ref)))
                                                    (list (substring ref 13) :sha sha :remote t)))))
                                         (split-string out "\n" t)))))))
      (my-wt-run dir (my-wt-arc) '("branch" "--list" "--all" "--json")
        (lambda (status out err)
          (funcall callback
                   (if (/= status 0) (list :error (my-wt-clean-error err))
                     (mapcar (lambda (b) (list (plist-get b :name) :local (plist-get b :local) :remote (not (plist-get b :local))))
                             (condition-case nil (my-wt-json out) (error nil))))))))))

(defun my-wt-filter (query items &optional key limit)
  "Literal, case-insensitive substring matches of QUERY among ITEMS' KEY strings.
Never a regexp; blank queries match nothing.  Return (MATCHES . MORE-P)."
  (let ((needle (downcase (string-trim query))) (limit (or limit 30)) result (count 0))
    (unless (string-empty-p needle)
      (dolist (name items)
        (when (string-search needle (downcase (if key (funcall key name) name)))
          (when (< count limit) (push name result))
          (cl-incf count))))
    (cons (nreverse result) (> count limit))))

;;; Creation

(defun my-wt-git-occupant (copy branch)
  "Directory where BRANCH is checked out among Git worktrees of COPY, or nil."
  (let ((out (cdr (my-wt-call (plist-get copy :vcs_root) "git" "worktree" "list" "--porcelain")))
        path found)
    (dolist (line (split-string out "\n"))
      (cond ((string-prefix-p "worktree " line) (setq path (substring line 9)))
            ((equal line (concat "branch refs/heads/" branch)) (setq found (my-wt-dir path)))))
    found))

(defun my-wt-resolve-start (copy)
  "Current commit of COPY, captured now so later source switches cannot change it."
  (my-wt-rev-parse copy "HEAD"))

(defun my-wt-rev-parse (copy revision)
  "Commit ID of REVISION as resolved in COPY itself."
  (pcase (if (equal (plist-get copy :vcs) "git")
             (my-wt-call (plist-get copy :directory) "git" "rev-parse" "--verify" (concat revision "^{commit}"))
           (my-wt-call (plist-get copy :directory) (my-wt-arc) "rev-parse" revision))
    ((and `(0 . ,out) (guard (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" (string-trim out)))) (string-trim out))
    (_ (user-error "Cannot resolve %s in %s" revision (plist-get copy :directory)))))

(cl-defun my-wt-plan (source spec)
  "Validate an existing branch SPEC (:branch :sha :remote) for SOURCE.
Return (:occupied COPY) when an existing registered copy already has the branch."
  (when (plist-get spec :new)
    (user-error "Creating branches is disabled; select an existing local branch"))
  (let* ((vcs (plist-get source :vcs)) (branch (plist-get spec :branch)) (dir (plist-get source :vcs_root))
         ;; origin/foo and cloudia/users/x/foo become local foo and users/x/foo.
         (local (if (plist-get spec :remote) (replace-regexp-in-string "\\`[^/]+/" "" branch) branch)))
    (unless (member vcs '("git" "arc")) (user-error "This project is not in a Git repository or Arc mount"))
    (unless (equal (plist-get source :state) "ready") (user-error "The source copy is not available"))
    (when (string-empty-p (string-trim (or branch ""))) (user-error "Enter a branch name"))
    (when (equal vcs "arc")
      (unless (and (plist-get spec :arc-verified) (plist-get spec :remote-ref)
                   (my-wt-commit-id-p (plist-get spec :sha)))
        (user-error "Preview and verify the Arc server branch before creating a copy"))
      (cl-return-from my-wt-plan spec))
    (if (equal vcs "git")
        (progn
          (unless (zerop (car (my-wt-call dir "git" "check-ref-format" "--branch" local)))
            (user-error "Invalid Git branch name: %s" local))
          (let ((exists (zerop (car (my-wt-call dir "git" "rev-parse" "--verify" "--quiet" (concat "refs/heads/" local))))))
            (unless exists
              (user-error "Local branch %s does not exist; creating branches is disabled" local))
            (when-let* ((occupant (my-wt-git-occupant source local)))
              (if-let* ((copy (car (my-wt--select "WHERE project_id=? AND vcs_root=? AND state<>'deleted'"
                                                  (list (plist-get source :project_id) occupant)))))
                  (cl-return-from my-wt-plan (list :occupied copy))
                (user-error "Branch %s is checked out in an external worktree at %s; it was not forced"
                            local occupant)))
            (append (list :local local :exists exists) spec)))
      (error "Unsupported worktree backend"))))

(defun my-wt-create (source spec &optional callback)
  "Create a copy of SOURCE's project as planned by SPEC; CALLBACK gets the copy."
  (let* ((plan (my-wt-plan source spec)))
    (if (plist-get plan :occupied)
        (progn (when callback (funcall callback (plist-get plan :occupied))) plan)
      (let* ((project (my-wt-project (plist-get source :project_id)))
             (vcs (plist-get source :vcs))
             (place (my-wt-allocate project vcs (plist-get plan :local)))
             (root (cdr place))
             (directory (file-name-as-directory (expand-file-name (or (plist-get source :relative_path) "") root)))
             (id (my-pi-history-id)))
        (when (and (equal vcs "arc") (not (plist-get plan :sha)))
          (user-error "The starting revision is unknown"))
        (my-wt-write
         (lambda (db)
           (sqlite-execute db "INSERT INTO working_copies(copy_id,project_id,role,directory,vcs_root,relative_path,vcs,
               arc_repository,owned,state,tree_name,branch,start_revision,created_at)
               VALUES (?,?,'copy',?,?,?,?,?,1,'creating',?,?,?,?)"
             (list id (plist-get project :id) directory root (or (plist-get source :relative_path) "") vcs
                   (plist-get source :arc_repository) (car place) (plist-get plan :local)
                   (or (plist-get plan :sha) (plist-get plan :start)) (my-pi-history-now)))))
        (when (equal vcs "arc")
          (my-wt-update id :source_copy_id (plist-get source :copy_id) :arc_remote_ref (plist-get plan :remote-ref)))
        (my-wt-build (my-wt-copy id) plan callback)
        (my-wt-copy id)))))

(defun my-wt-build (copy plan callback)
  "Run (or resume) the VCS steps that turn the creating record COPY into a ready copy."
  (let* ((id (plist-get copy :copy_id)) (source (or (and (plist-get copy :source_copy_id) (my-wt-copy (plist-get copy :source_copy_id)))
                     (my-wt-original (plist-get copy :project_id)))))
    (puthash id t my-wt-busy)
    (make-directory (file-name-directory (directory-file-name (plist-get copy :vcs_root))) t)
    (my-wt-chain
     (if (equal (plist-get copy :vcs) "git") (my-wt-git-steps source copy plan) (my-wt-arc-steps source copy plan))
     (lambda (error)
       (remhash id my-wt-busy)
       (if error
           (my-wt-update id :state "failed" :error error)
         (my-wt-update id :state "ready" :error nil))
       (let ((copy (my-wt-copy id)))
         (if error (message "Working copy %s failed: %s" (plist-get copy :tree_name) error)
           (my-wt-refresh-branch copy))
         (when callback (funcall callback copy)))))))

(defun my-wt-git-steps (source copy plan)
  (let ((root (directory-file-name (plist-get copy :vcs_root))) (local (plist-get plan :local)))
    (list
     (lambda (next)
       ;; A worktree registered by an interrupted attempt is resumed, not duplicated.
       (if (and (file-exists-p (expand-file-name ".git" root))
                (member (concat "worktree " (directory-file-name root))
                        (split-string (cdr (my-wt-call (plist-get source :vcs_root) "git"
                                                       "worktree" "list" "--porcelain")) "\n")))
           (funcall next)
         ;; Bare names let worktree add create a branch from a matching remote.
         (funcall (my-wt-step (plist-get source :vcs_root) "git"
                             (list "worktree" "add" "--detach" root (concat "refs/heads/" local))) next)))
     (my-wt-step root "git" (list "switch" "--no-guess" local))
     (lambda (next)
       (funcall next (unless (file-directory-p (plist-get copy :directory))
                       (format "%s does not exist on branch %s" (plist-get copy :relative_path) local)))))))

(defun my-wt-mount-entry (entries directory)
  (cl-find-if (lambda (e) (equal (my-wt-dir (plist-get e :mount)) (my-wt-dir directory))) entries))

(defun my-wt-retry (copy &optional callback)
  "Resume a failed creation of COPY without creating another record or directory."
  (unless (equal (plist-get copy :state) "failed") (user-error "Only failed copies can be retried"))
  (let ((branch (plist-get copy :branch)) (start (plist-get copy :start_revision)))
    (my-wt-update (plist-get copy :copy_id) :state "creating" :error nil)
    (my-wt-build (my-wt-copy (plist-get copy :copy_id))
                 (list :local branch :sha start :remote-ref (plist-get copy :arc_remote_ref))
                 callback)))

;;; Deletion

(defun my-wt-copy-buffers (copy)
  (let ((root (plist-get copy :vcs_root)))
    ;; Internal (space-named) buffers include this module's own process buffers.
    (cl-remove-if-not (lambda (b) (when-let* ((dir (buffer-local-value 'default-directory b)))
                                    (and (not (string-prefix-p " " (buffer-name b)))
                                         (not (file-remote-p dir)) (file-in-directory-p dir root))))
                      (buffer-list))))

(defun my-wt-delete-blockers (copy &optional recheck)
  "Reasons why COPY cannot be deleted; RECHECK skips state checks during deletion."
  (let* ((buffers (my-wt-copy-buffers copy))
         (agents (cl-remove-if-not (lambda (b) (and (fboundp 'my-pi-live-p) (my-pi-live-p b))) buffers))
         (agent-stderr (delq nil (mapcar #'my-pi-stderr-process agents)))
         blockers)
    (unless (equal (plist-get copy :role) "copy") (push "The original working directory is never deleted" blockers))
    (unless (equal (plist-get copy :owned) 1) (push "This copy was not created by Emacs" blockers))
    (unless recheck
      (when (member (plist-get copy :state) '("creating" "preparing" "deleting" "deleted"))
        (push (format "The copy is %s" (plist-get copy :state)) blockers))
      (when (gethash (plist-get copy :copy_id) my-wt-busy) (push "Another operation is running" blockers)))
    (when-let* ((dirty (cl-remove-if-not (lambda (b) (and (buffer-file-name b) (buffer-modified-p b))) buffers)))
      (push (format "Unsaved buffers: %s" (mapconcat #'buffer-name dirty ", ")) blockers))
    (when-let* ((busy (cl-remove-if-not (lambda (b) (memq (agent-shell-status :shell-buffer b) '(busy blocked))) agents)))
      (push (format "An agent task is running in %s; stop the task first" (mapconcat #'buffer-name busy ", ")) blockers))
    (when-let* ((others (cl-remove-if-not
                         (lambda (p) (and (process-live-p p) (memq (process-buffer p) buffers)
                                          (not (process-get p 'my-wt-releasable))
                                          (not (memq p agent-stderr))
                                          (not (with-current-buffer (process-buffer p)
                                                 (or (derived-mode-p 'agent-shell-mode)
                                                     (bound-and-true-p eglot--managed-mode))))))
                         (process-list))))
      (push (format "Processes still run there: %s" (mapconcat #'process-name others ", ")) blockers))
    (nreverse blockers)))

(defun my-wt-release (copy)
  "Release editor resources rooted in COPY; other copies' processes are untouched."
  (let ((root (plist-get copy :vcs_root)) (current (tab-bar--current-tab-index)))
    (dolist (tab (tab-bar-tabs))
      (when (equal (alist-get 'my-project-root tab) (plist-get copy :directory))
        (tab-bar-select-tab (1+ (tab-bar--tab-index tab)))
        (my-wt-switch (my-wt-original (plist-get copy :project_id)))))
    (tab-bar-select-tab (1+ current))
    (when (boundp 'eglot--servers-by-project)
      (maphash (lambda (project servers)
                 (when (file-in-directory-p (project-root project) root)
                   (dolist (server servers) (eglot-shutdown server))))
               eglot--servers-by-project))
    (dolist (buffer (my-wt-copy-buffers copy))
      (unless (and (buffer-file-name buffer) (buffer-modified-p buffer))
        (let ((kill-buffer-query-functions nil)) (quit-windows-on buffer t))))
    (remhash (plist-get copy :directory) my-wt-states)
    (project-forget-project (plist-get copy :directory))))

(defun my-wt-release-step (copy)
  "Release COPY's editor resources, reporting errors to the deletion chain."
  (lambda (next)
    (funcall next
             (condition-case failure
                 (progn (my-wt-release copy) nil)
               ((error quit) (format "Could not release editor resources: %s"
                                     (error-message-string failure)))))))

(defun my-wt-git-delete-steps (copy)
  (let ((root (directory-file-name (plist-get copy :vcs_root)))
        (main (plist-get (my-wt-original (plist-get copy :project_id)) :vcs_root)))
    (list
     (my-wt-step root "git" '("rev-parse" "--show-toplevel")
       (lambda (out) (unless (equal (my-wt-dir (string-trim out)) (my-wt-dir root))
                       "The directory is no longer the recorded worktree")))
     (my-wt-step main "git" '("worktree" "list" "--porcelain")
       (lambda (out) (unless (member (concat "worktree " root) (split-string out "\n"))
                       "Git does not list this directory as a worktree of the project")))
     (my-wt-step root "git" '("status" "--porcelain" "--ignored" "--untracked-files=all")
       (lambda (out) (unless (string-empty-p (string-trim out))
                       (format "The copy has changed, untracked or ignored files:\n%s" (truncate-string-to-width out 600)))))
     (my-wt-step root "git" '("rev-list" "-n" "1" "HEAD" "--not" "--branches" "--remotes" "--tags")
       (lambda (out) (unless (string-empty-p (string-trim out))
                       "HEAD has commits that no branch, tag or remote keeps")))
     (my-wt-release-step copy)
     (my-wt-step main "git" (list "worktree" "remove" root)))))

(defun my-wt-delete (copy &optional callback expected)
  "Delete application-owned COPY after its safety checks; keep its records and chats."
  (when-let* ((blockers (my-wt-delete-blockers copy)))
    (user-error "%s" (string-join blockers "; ")))
  (let ((id (plist-get copy :copy_id)) (previous (plist-get copy :state)))
    (puthash id t my-wt-busy)
    (my-wt-update id :state "deleting" :error nil)
    ;; Releasing kills idle agent buffers, which shuts their adapters down.
    (my-wt-chain
     (cons (lambda (next) (funcall next (car (my-wt-delete-blockers copy t))))
           (if (equal (plist-get copy :vcs) "git") (my-wt-git-delete-steps copy) (my-wt-arc-delete-steps copy expected)))
     (lambda (error)
       (remhash id my-wt-busy)
       (if error
           (progn (my-wt-update id :state (cond ((equal previous "failed") "failed")
                                                   ((and (equal (plist-get copy :vcs) "arc") (not (my-wt-arc-mounted-p copy))) "unavailable")
                                                   (t "ready")) :error error)
                  (message "Working copy was not deleted: %s" error))
         (my-wt-update id :state "deleted" :error nil)
         (message "Working copy %s deleted; %s" (plist-get copy :tree_name)
                  (if (equal (plist-get copy :vcs) "git") "its branch and chats were kept" "server branches and chats were kept")))
       (when callback (funcall callback error))))))

;;; Reconciliation

(defun my-wt-reconcile (project-id)
  "Bring records of PROJECT-ID in line with the filesystem after a restart."
  (dolist (copy (my-wt-copies project-id))
    (let ((id (plist-get copy :copy_id)) (state (plist-get copy :state)))
      (unless (gethash id my-wt-busy)
        (pcase state
          ((or "creating" "preparing")
           (my-wt-update id :state "failed" :error "Creation was interrupted; retry or delete"))
          ("deleting"
           (if (equal (plist-get copy :vcs) "arc")
               (my-wt-arc-reconcile-deletion copy)
             (if (file-exists-p (plist-get copy :vcs_root))
                 (my-wt-update id :state "ready" :error "Deletion was interrupted; nothing was removed by force")
               (my-wt-update id :state "deleted"))))
          ("ready" (unless (my-wt-usable-p copy)
                     (my-wt-update id :state "unavailable" :error "Directory is missing, unmounted or not the recorded copy")))
          ("unavailable" (when (my-wt-usable-p copy) (my-wt-update id :state "ready" :error nil))))))))

;;; Editor state per copy

(defun my-wt-save-files (directory buffers)
  "Persist DIRECTORY's file list so a restart can reopen it."
  (let ((state-file (my-project-files-state-file directory)))
    (make-directory (file-name-directory state-file) t)
    (with-temp-file state-file
      (let ((print-length nil) (print-level nil))
        (prin1 (delq nil (mapcar #'buffer-file-name (seq-filter #'buffer-live-p buffers))) (current-buffer))))))

(defun my-wt-save-inactive (&rest _)
  "Write file lists of copies that are not shown in any tab."
  (maphash (lambda (dir state) (my-wt-save-files dir (append (nth 1 state) (nth 2 state)))) my-wt-states))

(defun my-wt-report-missing (directory)
  (when-let* ((gone (cl-remove-if-not
                     (lambda (b) (and (buffer-file-name b) (file-in-directory-p (buffer-file-name b) directory)
                                      (not (file-exists-p (buffer-file-name b)))))
                     (buffer-list))))
    (message "No longer on disk (buffers and edits kept, nothing written): %s"
             (mapconcat #'buffer-name gone ", "))))

(defun my-wt-show-tree (directory)
  (let ((default-directory directory) (editor (selected-window)))
    (treemacs-tab-bar--on-tab-switch)
    (treemacs-add-and-display-current-project-exclusively)
    (when (window-live-p editor) (select-window editor))))

(defun my-wt-switch (copy)
  "Make COPY the active working copy of the current project tab."
  (let* ((tab (tab-bar--current-tab)) (old (alist-get 'my-project-root tab))
         (dir (plist-get copy :directory)))
    (unless (equal (plist-get (my-wt-copy-at old) :project_id) (plist-get copy :project_id))
      (error "Copy belongs to another project"))
    (unless (equal old dir)
      (unless (my-wt-usable-p copy)
        (when (equal (plist-get copy :state) "ready")
          (my-wt-update (plist-get copy :copy_id) :state "unavailable" :error "Directory is missing, unmounted or not the recorded copy"))
        (user-error "Working copy %s is %s" dir (if (member (plist-get copy :state) '("ready" "unavailable")) "unavailable"
                                                  (plist-get copy :state))))
      (let ((buffers (frame-parameter nil 'buffer-list)) (buried (frame-parameter nil 'buried-buffer-list)))
        (puthash old (list (current-window-configuration) buffers buried) my-wt-states)
        (my-wt-save-files old (append buffers buried)))
      (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) dir)
      (project-remember-project (cons 'transient dir))
      (let ((state (gethash dir my-wt-states)))
        (if state
            (progn (set-window-configuration (car state))
                   (set-frame-parameter nil 'buffer-list (seq-filter #'buffer-live-p (nth 1 state)))
                   (set-frame-parameter nil 'buried-buffer-list (seq-filter #'buffer-live-p (nth 2 state))))
          (when (window-parameter nil 'window-side)
            (select-window (or (seq-find (lambda (w) (not (window-parameter w 'window-side))) (window-list)) (selected-window))))
          (delete-other-windows)
          (dired dir)
          (tabspaces-reset-buffer-list)
          (my-project-restore-files dir)))
      (remhash dir my-wt-states)
      (when (fboundp 'my-pi-after-select) (my-pi-after-select tab (tab-bar--current-tab)))
      (my-wt-show-tree dir)
      (my-wt-report-missing dir))
    (my-wt-set-active copy)
    (my-wt-refresh-branch copy)
    (dolist (window (window-list))
      (with-current-buffer (window-buffer window)
        (when (and buffer-file-name (file-in-directory-p buffer-file-name dir)) (vc-refresh-state))))
    copy))

;;; Header above the file tree

(defvar my-wt-attention-cache (make-hash-table :test #'equal))
(add-hook 'my-pi-history-change-hook (lambda () (clrhash my-wt-attention-cache)))
(add-hook 'my-wt-change-hook (lambda () (clrhash my-wt-attention-cache)))

(defun my-wt-attention (copy)
  "Plist (:running :input :unread) for COPY's chats."
  (with-memoization (gethash (plist-get copy :directory) my-wt-attention-cache)
    (let ((row (car (sqlite-select (my-pi-history-open)
                     "SELECT SUM(turn_state='running'),SUM(turn_state='needs-input'),
                             SUM(last_reply_id IS NOT NULL AND last_reply_id IS NOT read_reply_id)
                      FROM chats WHERE project_root=? AND deleting=0" (list (plist-get copy :directory))))))
      (list :running (or (nth 0 row) 0) :input (or (nth 1 row) 0) :unread (or (nth 2 row) 0)))))

(defun my-wt-attention-text (attention)
  (string-join (delq nil (list (unless (zerop (plist-get attention :input)) (format "%d needs input" (plist-get attention :input)))
                               (unless (zerop (plist-get attention :running)) (format "%d running" (plist-get attention :running)))
                               (unless (zerop (plist-get attention :unread)) (format "%d unread" (plist-get attention :unread)))))
               " · "))

(defun my-wt-header-button (text help action)
  (propertize text 'mouse-face 'mode-line-highlight 'help-echo help
              'local-map (let ((map (make-sparse-keymap)))
                           (define-key map [header-line down-mouse-1] #'ignore)
                           (define-key map [header-line mouse-1] action) map)))

(defvar my-wt-header-refreshed nil)
(defun my-wt-header ()
  "Copy role, active branch, attention marker and a + button for the tree header."
  (if-let* ((copy (ignore-errors (my-wt-tab-copy))))
      (let* ((others (cl-remove-if (lambda (c) (or (equal c copy) (equal (plist-get c :state) "deleted")))
                                   (my-wt-copies (plist-get copy :project_id))))
             (attention (mapconcat (lambda (c) (my-wt-attention-text (my-wt-attention c))) others ""))
             (original (equal (plist-get copy :role) "original"))
             (icon (propertize (if original "⌂ " "⧉ ") 'face '(:height 0.9)))
             (label (my-wt-label copy))
             (help (format "%s\n%s\n%s" (if original "Original" "Working copy")
                           label (plist-get copy :directory)))
             (open (lambda () (interactive) (my-wt-picker-show))))
        (unless (or (gethash (plist-get copy :directory) my-wt-branches)
                    (equal my-wt-header-refreshed (plist-get copy :directory)))
          (setq my-wt-header-refreshed (plist-get copy :directory))
          (run-at-time 0 nil #'my-wt-refresh-branch copy))
        ;; Keep the role icon and controls visible even with a long branch name.
        (concat (propertize " " 'display '(space :width (6) :height 1.3 :ascent 75)) ; padding; tab-line height
                (my-wt-header-button icon help open)
                (my-wt-header-button
                 (truncate-string-to-width label (max 1 (- (window-width) (string-width icon)
                                                           (if (string-empty-p attention) 5 7)))
                                           nil nil "…")
                 help open)
                (unless (string-empty-p attention)
                  (propertize " ●" 'face 'warning 'help-echo (concat "Other copies: " attention)))
                (propertize " " 'display '(space :align-to (- right 3)))
                (my-wt-header-button " + " "Working copies: switch, create or delete" open)))
    ""))

(defface my-wt-header-frame
  '((t (:background "#a3a29b" :box (:line-width (-1 . -1) :color "#73726b"))))
  "One thin, square frame around the whole branch row above the file tree."
  :group 'faces)

(defun my-wt-frame-header ()
  "Draw the tree's header line, selected or not, as one framed row.
Remapping the header-line faces styles every fragment and the stretch
space alike, so the box has no seams between them."
  (dolist (face '(header-line header-line-active header-line-inactive))
    (face-remap-add-relative face 'my-wt-header-frame)))

(defun my-wt-refresh-active ()
  "Refresh branch labels of copies shown in tabs; external checkouts become visible."
  (dolist (tab (tab-bar-tabs))
    (when-let* ((copy (ignore-errors (my-wt-tab-copy tab))))
      (my-wt-refresh-branch copy))))

(setq treemacs-user-header-line-format '(:eval (my-wt-header)))
(add-hook 'treemacs-mode-hook #'my-wt-frame-header)
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'treemacs-mode)
      (setq header-line-format treemacs-user-header-line-format)
      (unless (assq 'header-line face-remapping-alist) (my-wt-frame-header)))))
(add-hook 'my-wt-change-hook (lambda () (force-mode-line-update t)))
(unless noninteractive
  (run-with-idle-timer 15 t #'my-wt-refresh-active)
  (add-function :after after-focus-change-function #'my-wt-refresh-active))

;; Generated copies are never part of the configuration's own tree.
(with-eval-after-load 'treemacs
  (add-to-list 'treemacs-ignored-file-predicates
               (lambda (_name path) (equal (directory-file-name path) (directory-file-name (my-wt-base))))))

(provide 'my-worktrees)

(load (expand-file-name "worktrees-arc.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
