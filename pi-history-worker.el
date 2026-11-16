;;; pi-history-worker.el --- Offline Pi JSONL / FTS worker -*- lexical-binding: t; -*-
(load (expand-file-name "pi-history.el" (file-name-directory load-file-name)) nil t)

(defun my-pi-history-entries (file)
  "Read complete JSON entries; a partially written final line is ignored."
  (with-temp-buffer
    (insert-file-contents file)
    (let (entries)
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (unless (string-blank-p line)
            (condition-case err
                (push (json-parse-string line :object-type 'alist :array-type 'list :null-object nil :false-object nil) entries)
              (error
               (unless (= (line-end-position) (point-max)) (signal (car err) (cdr err)))))))
        (forward-line 1))
      (nreverse entries))))

(defun my-pi-history-projection (entries)
  "Mirror Pi's persisted leaf, compaction and context-edit selection."
  (let ((index (make-hash-table :test #'equal)) (visited (make-hash-table :test #'equal))
        leaf path compaction kept)
    (dolist (entry (cdr entries))
      (when (alist-get 'id entry) (puthash (alist-get 'id entry) entry index) (setq leaf entry)))
    (while leaf
      (when (gethash (alist-get 'id leaf) visited) (error "Cycle in Pi session history"))
      (puthash (alist-get 'id leaf) t visited)
      (push leaf path)
      (setq leaf (gethash (alist-get 'parentId leaf) index)))
    (dolist (entry path)
      (when (equal (alist-get 'type entry) "compaction") (setq compaction entry)))
    (if (not compaction) (setq kept path)
      (let ((retain nil) (after nil))
        (dolist (entry path)
          (cond ((eq entry compaction) (setq after t))
                (after (push entry kept))
                (t (when (equal (alist-get 'id entry) (alist-get 'firstKeptEntryId compaction)) (setq retain t))
                   (when retain (push entry kept)))))
        (setq kept (nreverse kept))))
    (let ((edits (make-hash-table :test #'equal)) result (ordinal 0))
      (dolist (entry kept)
        (when (equal (alist-get 'type entry) "context_edit") (puthash (alist-get 'targetId entry) entry edits)))
      (dolist (entry kept)
        (when (equal (alist-get 'type entry) "message")
          (let* ((message (alist-get 'message entry)) (role (alist-get 'role message))
                 (edit (gethash (alist-get 'id entry) edits))
                 (content (if edit (alist-get 'content (alist-get 'replacement edit)) (alist-get 'content message)))
                 (text (if (stringp content) content
                         (mapconcat (lambda (block) (if (equal (alist-get 'type block) "text")
                                                       (or (alist-get 'text block) "") "")) content ""))))
            (when (and (member role '("user" "assistant")) (not (string-empty-p text)))
              (push (list :id (alist-get 'id entry) :role role :body text :ordinal ordinal
                          :timestamp (alist-get 'timestamp entry) :stop (alist-get 'stopReason message)) result)
              (cl-incf ordinal)))))
      (nreverse result))))

(cl-defun my-pi-history-index-file (file root &optional binding)
  (let* ((file (file-truename file)) (root (my-pi-history-root root))
         (header (my-pi-history-file-header file))
         (id (if binding (alist-get 'sessionId binding) (alist-get 'id header)))
         (db (my-pi-history-open)) (old (my-pi-history-get id))
         (aliases (sqlite-select db "SELECT * FROM chats WHERE session_file=? AND session_id<>?" (list file id)))
         (repair (or aliases (and old binding (not (plist-get old :fingerprint))
                                  (or (not (equal id (alist-get 'id header)))
                                      (not (equal root (my-pi-history-root (alist-get 'cwd header))))))))
         (attrs (file-attributes file))
         (fingerprint (format "%s/%s" (file-attribute-size attrs) (file-attribute-modification-time attrs))))
    (unless (and (equal (alist-get 'type header) "session") (stringp (alist-get 'id header))
                 (stringp (alist-get 'cwd header))
                 (if binding (my-pi-history-binding-matches-p binding id root file)
                   (equal root (my-pi-history-root (alist-get 'cwd header)))))
      (error "Session header does not belong to this project: %s" file))
    (unless (or (and (not repair) (equal (plist-get old :deleting) 1))
                (and (not repair) (equal root (plist-get old :project_root))
                     (equal fingerprint (plist-get old :fingerprint))))
      (let ((entries (my-pi-history-entries file)))
        (let* ((messages (my-pi-history-projection entries))
               (first-user (cl-find "user" messages :key (lambda (m) (plist-get m :role)) :test #'equal))
               (reply (cl-find-if (lambda (m) (and (equal (plist-get m :role) "assistant")
                                                  (not (member (plist-get m :stop) '("toolUse" "aborted" "error")))))
                                  (reverse messages)))
               (title (or (alist-get 'name (cl-find-if (lambda (e) (and (equal (alist-get 'type e) "session_info")
                                                                                     (not (string-empty-p (or (alist-get 'name e) "")))))
                                                      (reverse entries)))
                          (and first-user (truncate-string-to-width (replace-regexp-in-string "[\n\r]+" " " (plist-get first-user :body)) 80 nil nil "…"))
                          (plist-get old :title) "New chat")))
          (my-pi-history-transaction db
            ;; Legacy discovery created separate cards for ACP and JSONL IDs.
            (dolist (row aliases)
              (let ((alias (my-pi-history--row row)))
                (unless (plist-get old :read_reply_id)
                  (setq old (plist-put old :read_reply_id (plist-get alias :read_reply_id)))))
              (sqlite-execute db "UPDATE projects SET selected_session_id=? WHERE selected_session_id=? AND project_root=?"
                              (list id (car row) root))
              (sqlite-execute db "UPDATE projects SET selected_session_id=NULL WHERE selected_session_id=? AND project_root<>?"
                              (list (car row) root))
              (sqlite-execute db "DELETE FROM messages WHERE session_id=?" (list (car row)))
              (sqlite-execute db "DELETE FROM chats WHERE session_id=?" (list (car row))))
            (sqlite-execute db "UPDATE chats SET project_root=? WHERE session_id=?" (list root id))
            (sqlite-execute db "UPDATE projects SET selected_session_id=NULL WHERE selected_session_id=? AND project_root<>?"
                            (list id root))
            (my-pi-history--register id root file)
            (when repair
              ;; A confirmation for an unindexed "New chat" must not delete its real transcript.
              (sqlite-execute db "UPDATE chats SET deleting=0,read_reply_id=? WHERE session_id=?"
                              (list (plist-get old :read_reply_id) id)))
            (sqlite-execute db "UPDATE chats SET title=?, fingerprint=?,
              created_at=COALESCE(?,created_at),first_prompt_at=COALESCE(first_prompt_at,?),
              last_reply_at=?,last_reply_id=? WHERE session_id=?"
              (list title fingerprint (alist-get 'timestamp header) (plist-get first-user :timestamp)
                    (plist-get reply :timestamp) (plist-get reply :id) id))
            (when (and (equal (plist-get old :turn_state) "interrupted")
                       (plist-get old :pending_since) (plist-get reply :timestamp)
                       (>= (float-time (date-to-time (plist-get reply :timestamp)))
                           (float-time (date-to-time (plist-get old :pending_since)))))
              (sqlite-execute db "UPDATE chats SET turn_state='idle',pending_since=NULL WHERE session_id=?" (list id)))
            (sqlite-execute db "DELETE FROM messages WHERE session_id=?" (list id))
            (sqlite-execute db "INSERT INTO messages VALUES (?,'',-1,'title',?,'')" (list id title))
            (dolist (m messages)
              (sqlite-execute db "INSERT INTO messages VALUES (?,?,?,?,NULL,?)"
                (list id (plist-get m :id) (plist-get m :ordinal) (plist-get m :role) (plist-get m :body)))))))
      id)))

(defun my-pi-history-discover (root profile)
  "Use the latest ACP binding per file; fall back to headers for unmapped files."
  (let ((root (my-pi-history-root root)) (files (make-hash-table :test #'equal)) warnings)
    (condition-case err
        (dolist (entry (my-pi-history-mappings profile))
          (let* ((file (file-truename (alist-get 'sessionFile entry))) (previous (gethash file files)))
            (when (or (not previous)
                      (string-lessp (or (alist-get 'updatedAt previous) "") (or (alist-get 'updatedAt entry) "")))
              (puthash file entry files))))
      (error (push (error-message-string err) warnings)))
    (when (file-exists-p (plist-get profile :sessions))
      (dolist (file (directory-files-recursively (plist-get profile :sessions) "\\.jsonl\\'"))
        (let ((file (file-truename file)))
          (unless (gethash file files)
            (condition-case err
                (let ((header (my-pi-history-file-header file)))
                  (when (and (equal (alist-get 'type header) "session") (stringp (alist-get 'cwd header))
                             (equal root (my-pi-history-root (alist-get 'cwd header))))
                    (puthash file t files)))
              (error (push (format "%s: %s" (file-name-nondirectory file) (error-message-string err)) warnings)))))))
    (maphash
     (lambda (file binding)
       (condition-case err
           (let ((mapped (listp binding)))
             (when (and (or (not mapped) (equal root (my-pi-history-root (alist-get 'cwd binding))))
                        (not (and mapped (sqlite-select (my-pi-history-open)
                                           "SELECT 1 FROM deleted_chats WHERE session_id=?"
                                           (list (alist-get 'sessionId binding))))))
               (if (file-exists-p file)
                   (my-pi-history-index-file file root (and mapped binding))
                 (when mapped (my-pi-history--register (alist-get 'sessionId binding) root file)))))
         (error (push (format "%s: %s" (file-name-nondirectory file) (error-message-string err)) warnings)))) files)
    (nreverse warnings)))

(defun my-pi-history-worker-main ()
  (condition-case err
      (let* ((request (json-parse-string (read-string "") :object-type 'plist :array-type 'list :null-object nil))
             (user-emacs-directory (plist-get request :home))
             (root (plist-get request :root)) (query (plist-get request :query))
             (warnings (my-pi-history-discover root (plist-get request :profile)))
             (chats (if (string-blank-p query) (my-pi-history-list root)
                      (my-pi-history-query root query (plist-get request :offset)))))
        (dolist (chat chats)
          (when (plist-member chat :matches)
            (plist-put chat :matches (vconcat (plist-get chat :matches)))))
        (princ (decode-coding-string
                (json-serialize (list :query query :chats (vconcat chats) :warnings (vconcat warnings))
                                :null-object nil :false-object :false) 'utf-8)))
    (error (princ (error-message-string err) #'external-debugging-output) (kill-emacs 1))))
(provide 'my-pi-history-worker)
