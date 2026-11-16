;;; pi-history.el --- Persistent project chat catalogue -*- lexical-binding: t; -*-
(require 'sqlite)
(require 'json)
(require 'cl-lib)
(require 'subr-x)
(defvar my-pi-history-db nil)
(defvar my-pi-history-change-hook nil)
(defvar my-pi-history-instance (format "%s-%s" (emacs-pid) (float-time)))
(defconst my-pi-history-directory (file-name-directory load-file-name))
(defconst my-pi-history-columns
  '(session_id project_root session_file title created_at first_prompt_at last_reply_at
    last_reply_id read_reply_id turn_state owner_instance deleting fingerprint pending_since))

(defun my-pi-history-root (root)
  (file-name-as-directory (file-truename root)))
(defun my-pi-history-path () (expand-file-name "pi/chats.sqlite" user-emacs-directory))
(defun my-pi-history-now () (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ" nil t))

(defun my-pi-history-ensure-geometry (db)
  (dolist (column '(picker_left picker_top))
    (unless (member (symbol-name column) (mapcar #'cadr (sqlite-select db "PRAGMA table_info(projects)")))
      (sqlite-execute db (format "ALTER TABLE projects ADD COLUMN %s INTEGER" column)))))

(defmacro my-pi-history-transaction (db &rest body)
  (declare (indent 1))
  `(progn (sqlite-execute ,db "BEGIN IMMEDIATE")
          (condition-case err
              (prog1 (progn ,@body) (sqlite-execute ,db "COMMIT"))
            (error (ignore-errors (sqlite-execute ,db "ROLLBACK"))
                   (signal (car err) (cdr err))))))

(defun my-pi-history-open ()
  (or my-pi-history-db
      (let ((path (my-pi-history-path)))
        (make-directory (file-name-directory path) t)
        (setq my-pi-history-db (sqlite-open path))
        (sqlite-execute my-pi-history-db "PRAGMA journal_mode=WAL")
        (sqlite-execute my-pi-history-db "PRAGMA busy_timeout=50")
        (sqlite-execute my-pi-history-db "PRAGMA foreign_keys=ON")
        (when (> (caar (sqlite-select my-pi-history-db "PRAGMA user_version")) 1)
          (error "Pi history database was created by a newer configuration"))
        (sqlite-execute my-pi-history-db "CREATE TABLE IF NOT EXISTS chats (
          session_id TEXT PRIMARY KEY, project_root TEXT NOT NULL, session_file TEXT,
          title TEXT NOT NULL DEFAULT 'New chat', created_at TEXT NOT NULL,
          first_prompt_at TEXT, last_reply_at TEXT, last_reply_id TEXT, read_reply_id TEXT,
          turn_state TEXT NOT NULL DEFAULT 'idle', owner_instance TEXT,
          deleting INTEGER NOT NULL DEFAULT 0, fingerprint TEXT)")
        (sqlite-execute my-pi-history-db "CREATE INDEX IF NOT EXISTS chats_project ON chats(project_root)")
        (sqlite-execute my-pi-history-db "CREATE TABLE IF NOT EXISTS projects (
          project_root TEXT PRIMARY KEY, selected_session_id TEXT, picker_width INTEGER, picker_height INTEGER)")
        (my-pi-history-ensure-geometry my-pi-history-db)
        (unless (sqlite-select my-pi-history-db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='messages'")
          (sqlite-execute my-pi-history-db "UPDATE chats SET fingerprint=NULL"))
        (sqlite-execute my-pi-history-db "CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
          session_id UNINDEXED, message_id UNINDEXED, ordinal UNINDEXED, role UNINDEXED,
          title, body, tokenize='unicode61')")
        (sqlite-execute my-pi-history-db "CREATE TABLE IF NOT EXISTS deleted_chats (session_id TEXT PRIMARY KEY)")
        (unless (member "pending_since" (mapcar #'cadr (sqlite-select my-pi-history-db "PRAGMA table_info(chats)")))
          (sqlite-execute my-pi-history-db "ALTER TABLE chats ADD COLUMN pending_since TEXT"))
        (sqlite-execute my-pi-history-db "PRAGMA user_version=1")
        my-pi-history-db)))

;; Reloading the configuration can reuse a connection opened by the previous version.
(when my-pi-history-db (my-pi-history-ensure-geometry my-pi-history-db))

(defun my-pi-history--row (row)
  (let (result)
    (cl-mapc (lambda (key value)
               (setq result (plist-put result (if (eq key 'session_id) :id
                                                (intern (concat ":" (symbol-name key)))) value)))
             my-pi-history-columns row)
    (plist-put result :unread
               (and (plist-get result :last_reply_id)
                    (not (equal (plist-get result :last_reply_id) (plist-get result :read_reply_id)))))))
(defun my-pi-history-get (id)
  (when-let* ((row (car (sqlite-select (my-pi-history-open) "SELECT * FROM chats WHERE session_id=?" (list id)))))
    (my-pi-history--row row)))
(defun my-pi-history--register (id root &optional file)
  (let ((db (my-pi-history-open)) (root (my-pi-history-root root)))
    (when (sqlite-select db "SELECT 1 FROM deleted_chats WHERE session_id=?" (list id))
      (error "Chat has been deleted"))
    (when-let* ((old (my-pi-history-get id)))
      (unless (equal root (plist-get old :project_root)) (error "Chat belongs to another project")))
    (sqlite-execute db "INSERT INTO chats(session_id,project_root,session_file,created_at)
       VALUES (?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET session_file=COALESCE(excluded.session_file,chats.session_file)"
                    (list id root file (my-pi-history-now)))
    (my-pi-history-get id)))
(defun my-pi-history-register (id root &optional file)
  (let (result)
    (my-pi-history-write-retry
      (lambda () (setq result (my-pi-history--register id root file))) 0)
    result))
(defun my-pi-history--update (id &rest fields)
  (let ((db (my-pi-history-open)))
    (my-pi-history-transaction db
      (while fields
        (let* ((key (intern (substring (symbol-name (pop fields)) 1))) (value (pop fields)))
          (unless (memq key (cdr my-pi-history-columns)) (error "Invalid chat field %s" key))
          (sqlite-execute db (format "UPDATE chats SET %s=? WHERE session_id=?" key) (list value id))
          (when (eq key 'title)
            (sqlite-execute db "DELETE FROM messages WHERE session_id=? AND message_id=''" (list id))
            (sqlite-execute db "INSERT INTO messages VALUES (?,'',-1,'title',?,'')" (list id value))))))
  (run-hooks 'my-pi-history-change-hook)))
(defun my-pi-history-update (id &rest fields)
  "Write immediately, retrying bounded lock contention outside command hooks."
  (let ((home user-emacs-directory))
    (my-pi-history-write-retry
     (lambda () (let ((user-emacs-directory home)) (apply #'my-pi-history--update id fields))) 0)))
(defvar my-pi-history-write-queues (make-hash-table :test #'equal))
(defvar my-pi-history-write-timers (make-hash-table :test #'equal))
(defvar my-pi-history-writing (make-hash-table :test #'equal))
(defun my-pi-history-write-retry (action _attempt)
  "Serialize writes, including those arriving while an earlier write is blocked."
  (let ((key (my-pi-history-path)))
    (puthash key (nconc (gethash key my-pi-history-write-queues) (list (list action 0))) my-pi-history-write-queues)
    (unless (or (gethash key my-pi-history-writing) (gethash key my-pi-history-write-timers))
      (my-pi-history-drain-writes key))))
(defun my-pi-history-drain-writes (key)
  (remhash key my-pi-history-write-timers)
  (puthash key t my-pi-history-writing)
  (unwind-protect
      (let (blocked)
        (while (and (not blocked) (gethash key my-pi-history-write-queues))
          (let ((entry (car (gethash key my-pi-history-write-queues))))
            (condition-case err
                (progn (funcall (car entry))
                       (puthash key (cdr (gethash key my-pi-history-write-queues)) my-pi-history-write-queues))
              (error
               (if (and (memq 'sqlite-error (get (car err) 'error-conditions)) (< (cadr entry) 20)
                        (string-match-p "locked\\|busy" (error-message-string err)))
                   (progn
                     (setcar (cdr entry) (1+ (cadr entry)))
                     (setq blocked t)
                     (puthash key (run-with-timer 0.1 nil #'my-pi-history-drain-writes key) my-pi-history-write-timers))
                 (puthash key (cdr (gethash key my-pi-history-write-queues)) my-pi-history-write-queues)
                 (signal (car err) (cdr err))))))))
    (remhash key my-pi-history-writing)))

(defun my-pi-history-list (root)
  (mapcar #'my-pi-history--row
          (sqlite-select (my-pi-history-open)
           "SELECT * FROM chats WHERE project_root=? ORDER BY
            CASE WHEN last_reply_id IS NOT NULL AND last_reply_id IS NOT read_reply_id THEN 0
                 WHEN turn_state IN ('running','needs-input') THEN 1 ELSE 2 END,
            COALESCE(last_reply_at,first_prompt_at,created_at) DESC, session_id"
           (list (my-pi-history-root root)))))
(defun my-pi-history-select (root id)
  (sqlite-execute (my-pi-history-open)
   "INSERT INTO projects(project_root,selected_session_id) VALUES (?,?)
    ON CONFLICT(project_root) DO UPDATE SET selected_session_id=excluded.selected_session_id"
   (list (my-pi-history-root root) id)))
(defun my-pi-history-selected (root)
  (caar (sqlite-select (my-pi-history-open) "SELECT selected_session_id FROM projects WHERE project_root=?"
                      (list (my-pi-history-root root)))))

(defun my-pi-history-fts-query (query)
  "Search unquoted prefixes and exact quoted phrases, never raw FTS syntax."
  (let ((pos 0) parts)
    (while (string-match "\"\\([^\"]*\\)\"?\\|\\([^[:space:]\"]+\\)" query pos)
      (let ((part (or (match-string 1 query) (match-string 2 query)))
            (quoted (match-string 1 query))
            (next (match-end 0)))
        (when (string-match-p "[[:alnum:]]" part)
          (push (concat "\"" (replace-regexp-in-string "\"" "\"\"" part) "\""
                        (unless quoted "*")) parts))
        (setq pos next)))
    (string-join (nreverse parts) " AND ")))
(defun my-pi-history-query (root query &optional offset)
  (let ((fts (my-pi-history-fts-query query)) (db (my-pi-history-open)) result)
    (unless (string-empty-p fts)
      (dolist (row (sqlite-select db
        "WITH hits AS MATERIALIZED (
          SELECT c.session_id, m.message_id='' AS is_title, bm25(messages) AS score, c.last_reply_at
          FROM messages m JOIN chats c ON c.session_id=m.session_id
          WHERE messages MATCH ? AND c.project_root=? AND c.deleting=0)
         SELECT session_id, MAX(is_title) AS title_hit, COUNT(*)
         FROM hits GROUP BY session_id ORDER BY title_hit DESC, MIN(score), last_reply_at DESC LIMIT 50 OFFSET ?"
        (list fts (my-pi-history-root root) (or offset 0))))
        (let ((chat (my-pi-history-get (car row))))
          (setq chat (plist-put chat :count (nth 2 row)))
          (setq chat (plist-put chat :matches
            (mapcar (lambda (r) (list :message-id (nth 0 r) :ordinal (nth 1 r)
                                     :snippet (nth 2 r)))
              (sqlite-select db
               "SELECT message_id,ordinal,snippet(messages,-1,char(1),char(2),'…',24)
                FROM messages WHERE messages MATCH ? AND session_id=? ORDER BY rank"
               (list fts (car row))))))
          (push chat result))))
    (nreverse result)))

(defun my-pi-history-profile ()
  "Resolve Pi history paths with the same environment as its ACP client."
  (let* ((overrides (and (boundp 'agent-shell-pi-environment) agent-shell-pi-environment))
         (value (lambda (key)
                  (let ((entry (cl-find-if (lambda (x) (if (stringp x) (string-prefix-p (concat key "=") x)
                                                        (equal (car-safe x) key))) overrides)))
                    (cond ((stringp entry) (substring entry (1+ (length key))))
                          ((consp entry) (funcall (cdr entry))) (t (getenv key))))))
         (home (or (funcall value "HOME") (expand-file-name "~")))
         (agent (expand-file-name (or (funcall value "PI_CODING_AGENT_DIR") ".pi/agent") home))
         (settings (expand-file-name "settings.json" agent))
         (dir (when (file-exists-p settings) (alist-get 'sessionDir (my-pi-history-read-json settings)))))
    (list :map (expand-file-name ".pi/pi-acp/session-map.json" home)
          :sessions (expand-file-name (or dir "sessions") agent))))
(defun my-pi-history-read-json (path)
  (with-temp-buffer (insert-file-contents path)
                    (json-parse-buffer :object-type 'alist :array-type 'list :null-object nil :false-object nil)))

(defun my-pi-history-mappings (&optional profile)
  "Read ACP identities; JSONL identities may differ for restored sessions."
  (let ((file (plist-get (or profile (my-pi-history-profile)) :map)))
    (when (file-exists-p file)
      (mapcar
       (lambda (pair)
         (let ((entry (cdr pair)))
           (unless (and (equal (symbol-name (car pair)) (alist-get 'sessionId entry))
                        (stringp (alist-get 'cwd entry)) (file-name-absolute-p (alist-get 'cwd entry))
                        (stringp (alist-get 'sessionFile entry)) (file-name-absolute-p (alist-get 'sessionFile entry)))
             (error "Invalid Pi session mapping"))
           entry))
       (alist-get 'sessions (my-pi-history-read-json file))))))

(defun my-pi-history-file-mappings (file &optional profile)
  (when file
    (cl-remove-if-not
     (lambda (entry) (equal (file-truename file) (file-truename (alist-get 'sessionFile entry))))
     (my-pi-history-mappings profile))))

(defun my-pi-history-binding-matches-p (entry id root file)
  (and entry (equal id (alist-get 'sessionId entry))
       (equal (my-pi-history-root root) (my-pi-history-root (alist-get 'cwd entry)))
       file (equal (file-truename file) (file-truename (alist-get 'sessionFile entry)))))

(defun my-pi-history-file-header (file)
  (with-temp-buffer
    (insert-file-contents file nil 0 65536) (goto-char (point-min))
    (json-parse-string (buffer-substring-no-properties (point) (line-end-position)) :object-type 'alist)))

(defun my-pi-history-aliases (id)
  (delete-dups
   (cons id (mapcar (lambda (entry) (alist-get 'sessionId entry))
                   (my-pi-history-file-mappings (plist-get (my-pi-history-get id) :session_file))))))

(defun my-pi-history-search (root query callback &optional offset)
  "Refresh/index ROOT in a subprocess, then deliver results to CALLBACK."
  (let* ((output (generate-new-buffer " *Pi history worker*"))
         (errors (generate-new-buffer " *Pi history errors*"))
         (request (list :home user-emacs-directory :root (my-pi-history-root root)
                        :query query :offset (or offset 0) :profile (my-pi-history-profile)))
         (process
          (make-process :name "pi-history" :buffer output :stderr errors :noquery t
           :connection-type 'pipe :coding 'utf-8-unix
           :command (list (expand-file-name invocation-name invocation-directory) "-Q" "--batch"
                          "-l" (expand-file-name "pi-history-worker.el" my-pi-history-directory)
                          "--eval" "(my-pi-history-worker-main)")
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (unwind-protect
                   (unless (process-get proc 'cancelled)
                     (condition-case err
                         (if (= (process-exit-status proc) 0)
                             (funcall callback
                              (with-current-buffer output
                                (goto-char (point-min))
                                (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil :false-object nil)))
                           (funcall callback (list :error (with-current-buffer errors (string-trim (buffer-string))))))
                       (error (message "Pi history: %s" (error-message-string err)))))
                 (kill-buffer output) (kill-buffer errors)))))))
    (process-send-string process (concat (decode-coding-string (json-serialize request :null-object nil :false-object :false) 'utf-8) "\n"))
    (process-send-eof process)
    process))
(defun my-pi-history-cancel (process)
  (when (process-live-p process)
    (process-put process 'cancelled t) (delete-process process)))
(provide 'my-pi-history)

(defun my-pi-history-delete-finish (root id)
  "Remove metadata only after the session file is confirmed absent."
  (let ((chat (my-pi-history-get id)) (db (my-pi-history-open)))
    (unless (and chat (equal (my-pi-history-root root) (plist-get chat :project_root)))
      (error "Chat belongs to another project"))
    (when (and (plist-get chat :session_file) (my-pi-history-file-present-p (plist-get chat :session_file)))
      (error "Pi did not delete the session file; history retained"))
    (my-pi-history-transaction db
      (dolist (alias (my-pi-history-aliases id))
        (sqlite-execute db "INSERT OR IGNORE INTO deleted_chats VALUES (?)" (list alias))
        (sqlite-execute db "DELETE FROM messages WHERE session_id=?" (list alias))
        (sqlite-execute db "DELETE FROM chats WHERE session_id=?" (list alias))
        (sqlite-execute db "UPDATE projects SET selected_session_id=NULL WHERE selected_session_id=?" (list alias))))
    (run-hooks 'my-pi-history-change-hook)))

(defun my-pi-history-delete-rpc (id callback)
  "Delete via a dedicated ACP client, without creating a chat or model request."
  (let* ((command agent-shell-pi-acp-command)
         (client (acp-make-client :command (car command) :command-params (cdr command)
                  :environment-variables (agent-shell--resolve-environment-variables :environment-variables agent-shell-pi-environment)))
         timer done
         (finish (lambda (error)
                   (unless done
                     (setq done t)
                     (when timer (cancel-timer timer))
                     (acp-shutdown :client client)
                     (funcall callback error)))))
    (setq timer (run-with-timer 15 nil finish "Pi session deletion timed out"))
    (acp-send-request :client client :request (acp-make-initialize-request :protocol-version 1)
     :on-failure (lambda (&rest _) (funcall finish "Could not initialize Pi deletion client"))
     :on-success (lambda (_)
       (acp-send-request :client client :request (acp-make-session-delete-request :session-id id)
        :on-success (lambda (_) (funcall finish nil))
        :on-failure (lambda (&rest _) (funcall finish "Pi rejected session deletion")))))
    client))

(defun my-pi-history-delete (root ids)
  "Delete the already confirmed snapshot IDS in ROOT, one at a time."
  (let ((root (my-pi-history-root root)))
    ;; Validate the whole snapshot before any destructive action.
    (dolist (id ids)
      (unless (equal root (plist-get (my-pi-history-get id) :project_root))
        (user-error "Chat belongs to another project")))
    (my-pi-history-write-retry
     (lambda ()
       (let ((db (my-pi-history-open)))
         (my-pi-history-transaction db
           (dolist (id ids)
             (sqlite-execute db "UPDATE chats SET deleting=1,owner_instance=? WHERE session_id=?"
                             (list my-pi-history-instance id)))))
       (my-pi-history-delete-next root ids nil)) 0)))

(defun my-pi-history-delete-next (root ids errors &optional dead-buffers)
  (if (not ids)
      (progn
        (my-pi-update-headers)
        (message (if errors "Some chats could not be deleted: %s" "Chat history deleted")
                 (string-join (nreverse errors) "; "))
        (when (fboundp 'my-pi-history-after-delete) (my-pi-history-after-delete root))
        (dolist (buffer dead-buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))))
    (let* ((id (car ids)) (aliases (my-pi-history-aliases id))
           (buffers (delq nil (delete-dups (mapcar (lambda (alias) (gethash alias my-pi-sessions)) aliases))))
           (finish (lambda (error)
                     (unless error
                       (condition-case err (my-pi-history-delete-finish root id)
                         (error (setq error (error-message-string err)))))
                     (when error (push (format "%s: %s" id error) errors))
                     (unless error
                       (dolist (alias aliases) (remhash alias my-pi-sessions))
                       (dolist (buffer buffers)
                         (when (buffer-live-p buffer) (push buffer dead-buffers))))
                     (my-pi-history-delete-next root (cdr ids) errors dead-buffers))))
      (my-pi-stop-aliases-for-delete buffers
        (lambda (error)
          (if error (funcall finish error)
            (condition-case err (progn (my-pi-history-validate-delete root id) (my-pi-history-delete-rpc id finish))
              (error (funcall finish (error-message-string err))))))))))

(defun my-pi-stop-aliases-for-delete (buffers callback)
  (if (not buffers) (funcall callback nil)
    (my-pi-stop-for-delete (car buffers)
      (lambda (error)
        (if error (funcall callback error)
          (my-pi-stop-aliases-for-delete (cdr buffers) callback))))))

(defun my-pi-stop-for-delete (buffer callback)
  "Cancel a turn and close only its adapter before deleting its file."
  (if (not (my-pi-live-p buffer)) (funcall callback nil)
    (with-current-buffer buffer
      (agent-shell-interrupt t)
      (let* ((client (map-elt (agent-shell--state) :client))
             (process (map-elt client :process))
             (deadline (+ (float-time) 10)) timer closing)
        (setq timer
          (run-with-timer 0.1 0.1
           (lambda ()
             (cond
              ((not (process-live-p process))
               (cancel-timer timer)
               (when (buffer-live-p buffer) (with-current-buffer buffer (agent-shell--shutdown)))
               (funcall callback nil))
              ((> (float-time) deadline)
               (cancel-timer timer)
               (funcall callback "Task did not stop; session file was not deleted"))
              ((and (not closing) (buffer-live-p buffer)
                    (with-current-buffer buffer (not (agent-shell--active-requests-p (agent-shell--state)))))
               (setq closing t)
               ;; EOF lets pi-acp dispose its Pi child, unlike SIGKILL.
               (process-send-eof process))))))))))

(defun my-pi-history-recover (root)
  "Reconcile recorded work with saved completions, even for a cached index."
  (let ((db (my-pi-history-open)) (root (my-pi-history-root root)))
    (sqlite-execute db
     "UPDATE chats SET turn_state='interrupted' WHERE project_root=?
      AND turn_state IN ('running','needs-input') AND owner_instance IS NOT ?"
     (list root my-pi-history-instance))
    (sqlite-execute db
     "UPDATE chats SET turn_state='idle',pending_since=NULL WHERE project_root=?
      AND turn_state='interrupted' AND julianday(last_reply_at)>=julianday(pending_since)"
     (list root))))

(defun my-pi-history-file-present-p (file)
  "Prove absence by listing an accessible parent; never confuse EACCES with ENOENT."
  (let ((directory (file-name-directory (expand-file-name file))))
    (unless (file-accessible-directory-p directory)
      (error "Session directory is unavailable; deletion is not confirmed"))
    (member (file-name-nondirectory file) (directory-files directory nil nil t))))

(defun my-pi-history-resume-deletions (root)
  "Resume only deletion intents confirmed in a previous Emacs instance."
  (let ((ids (mapcar #'car (sqlite-select (my-pi-history-open)
               "SELECT session_id FROM chats WHERE project_root=? AND deleting=1 AND owner_instance IS NOT ?"
               (list (my-pi-history-root root) my-pi-history-instance)))))
    (when ids (my-pi-history-delete root ids))))

(defun my-pi-history-validate-delete (root id)
  "Reject stale/mismatched paths before asking the adapter to unlink anything."
  (let* ((chat (my-pi-history-get id)) (file (plist-get chat :session_file))
         (entry (cl-find id (my-pi-history-mappings) :key (lambda (e) (alist-get 'sessionId e)) :test #'equal)))
    (unless (equal (my-pi-history-root root) (plist-get chat :project_root))
      (error "Chat belongs to another project"))
    (when entry
      (unless (my-pi-history-binding-matches-p entry id root file)
        (error "Pi session mapping changed; refresh history before deleting")))
    (when (and file (my-pi-history-file-present-p file))
      (let ((header (my-pi-history-file-header file)))
        (unless (and (equal (alist-get 'type header) "session") (stringp (alist-get 'id header))
                     (or entry
                         (and (equal id (alist-get 'id header))
                              (stringp (alist-get 'cwd header))
                              (equal (my-pi-history-root root) (my-pi-history-root (alist-get 'cwd header))))))
          (error "Refusing to delete a file that does not match this chat"))))))
