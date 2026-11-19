;;; disk-changes.el --- Review external file changes before reloading -*- lexical-binding: t; -*-

;; A changed file is never reloaded silently: its buffer gets a header-line
;; notification and a mode-line indicator, and the user chooses to compare,
;; reload or keep the editor version.

(require 'cl-lib)
(require 'autorevert)
(require 'ediff)

(defvar my-disk-recovery-directory (locate-user-emacs-file "disk-conflicts/")
  "Where unsaved editor text is copied before reloading from disk.")

(defvar-local my-disk-baseline nil "Hash of the disk version the unsaved edits started from.")
(defvar-local my-disk-ack nil "Hash of a disk version the user chose to keep the editor over.")
(defvar-local my-disk-pending nil "Unresolved change: plist with :hash, :expanded and :again.")
(defvar-local my-disk-saved-header nil "(LOCALP . VALUE) of the header line replaced by a notification.")
(defvar-local my-disk-compare nil "Live comparison: plist with :control and :hash.")
(defvar-local my-disk-seen nil "Modification time and size of the disk version last examined.")
(defvar-local my-disk-source nil "Editor buffer a comparison snapshot was taken from.")
(defvar-local my-disk-snapshot-label nil)
(defvar-local my-disk-snapshot-hash nil)
(dolist (var '(my-disk-baseline my-disk-ack my-disk-pending my-disk-saved-header my-disk-compare my-disk-seen))
  (put var 'permanent-local t))
(defvar my-disk-timer nil)
(defvar revert-buffer-preserve-modes) ; bound by `revert-buffer' for `after-revert-hook' users

(defun my-disk-covered-p ()
  "Return non-nil for a local, plain file buffer that this workflow guards."
  (and buffer-file-name
       (not (string-prefix-p " " (buffer-name)))
       (not (file-remote-p buffer-file-name))
       ;; Compressed and archive files do not compare byte for byte.
       (not (find-file-name-handler buffer-file-name 'insert-file-contents-literally))
       (not (file-directory-p buffer-file-name))))

(defun my-disk-meta (file)
  "Return FILE's (MTIME SIZE), or nil when it does not exist."
  (when-let* ((attributes (file-attributes file)))
    (list (file-attribute-modification-time attributes) (file-attribute-size attributes))))

(defun my-disk-read ()
  "Return (HASH BYTES META) for one unchanging version of the visited file.
META is the (MTIME SIZE) of exactly those BYTES.  HASH is `missing' when
the file is unreadable, and nil when it kept changing during every read."
  (let ((file buffer-file-name) result)
    (dotimes (_ 3)
      (unless result
        (let* ((before (my-disk-meta file))
               (bytes (condition-case nil
                          (when (file-regular-p file)
                            (with-temp-buffer
                              (set-buffer-multibyte nil)
                              (insert-file-contents-literally file)
                              (buffer-string)))
                        (error nil)))
               (after (my-disk-meta file)))
          (when (equal before after)
            (setq result (list (if bytes (secure-hash 'sha1 bytes) 'missing) bytes after))))))
    (or result (list nil nil nil))))

(defun my-disk-editor-text ()
  (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))

(defun my-disk-same-as-editor-p (bytes)
  "Return non-nil when the editor text encodes to BYTES."
  (and bytes (equal bytes (encode-coding-string
                           (my-disk-editor-text)
                           (or buffer-file-coding-system 'utf-8-unix)))))

(defun my-disk-name () (file-name-nondirectory buffer-file-name))

;;; Detection

(defun my-disk-check (&optional buffer)
  "Notify about an unreviewed external change to BUFFER's file."
  (with-current-buffer (or buffer (current-buffer))
    (when (my-disk-covered-p)
      (if (verify-visited-file-modtime)
          (when my-disk-pending (my-disk-resolve))
        (let ((seen (my-disk-meta buffer-file-name)))
          ;; Same metadata as the version already examined: nothing new to read.
          (unless (and seen (equal seen my-disk-seen))
            (pcase-let ((`(,hash ,bytes ,meta) (my-disk-read)))
             ;; A file that kept changing while read stays unexamined for the next check.
             (when hash
              (setq my-disk-seen meta)
              (cond
               ((and my-disk-pending (equal hash (plist-get my-disk-pending :hash))))
               ((and bytes (or (equal hash my-disk-baseline)
                               (my-disk-same-as-editor-p bytes)))
                ;; Metadata-only change, or the disk already holds the editor text.
                ;; Only the time of the bytes just compared, never a newer write.
                (set-visited-file-modtime (car meta))
                (my-disk-resolve))
               ((equal hash my-disk-ack) (when my-disk-pending (my-disk-resolve)))
               (t (my-disk-notify hash)))))))))))

(defun my-disk-notify (hash)
  (setq my-disk-pending (list :hash hash :expanded t :again (and my-disk-pending t)))
  (my-disk-show-header)
  (force-mode-line-update t))

(defun my-disk-resolve ()
  (setq my-disk-pending nil)
  (my-disk-hide-header)
  (force-mode-line-update t))

(defun my-disk-check-visible ()
  "Check the file buffers shown in the selected frame."
  (setq my-disk-timer nil)
  (dolist (buffer (delete-dups (mapcar #'window-buffer (window-list nil 'nomini))))
    (with-demoted-errors "Disk change check: %S" (my-disk-check buffer))))

(defun my-disk-schedule (&rest _)
  "Coalesce navigation and focus events into one check after they settle."
  (unless (timerp my-disk-timer)
    (setq my-disk-timer (run-at-time 0.1 nil #'my-disk-check-visible))))

(defun my-disk-auto-revert (revert)
  "Notify instead of letting auto-revert reload a guarded buffer."
  (if (my-disk-covered-p)
      (progn (setq auto-revert-notify-modified-p nil)
             (with-demoted-errors "Disk change check: %S" (my-disk-check)))
    (funcall revert)))

(defun my-disk-record-baseline ()
  "Remember the disk version that the first unsaved edit starts from."
  (when (and (my-disk-covered-p) (verify-visited-file-modtime))
    (pcase-let ((`(,hash ,bytes ,meta) (my-disk-read)))
      ;; A write after the check above yields a newer snapshot: never adopt it.
      (when (and bytes (time-equal-p (car meta) (visited-file-modtime)))
        (setq my-disk-baseline hash)))))

(defun my-disk-reset ()
  "Forget conflict state once the buffer and file agree after save or revert."
  (setq my-disk-baseline nil my-disk-ack nil my-disk-seen nil)
  (when my-disk-pending (my-disk-resolve)))

;;; Notification

(defun my-disk-button (text help command)
  "Header or mode-line button TEXT that runs COMMAND in the clicked window."
  (let ((action (lambda (event)
                  (interactive "e")
                  (select-window (posn-window (event-start event)))
                  (call-interactively command)))
        (map (make-sparse-keymap)))
    (dolist (area '(header-line mode-line))
      (define-key map (vector area 'down-mouse-1) #'ignore)
      (define-key map (vector area 'mouse-1) action))
    (propertize text 'mouse-face 'mode-line-highlight 'help-echo help 'local-map map)))

(defconst my-disk-actions
  '((my-disk-compare "Compare" "Compare" "c" "Compare the editor and disk versions side by side")
    (my-disk-reload "Reload from Disk" "Reload" "r" "Replace the editor contents with the disk version")
    (my-disk-keep "Keep Editor Version" "Keep" "k" "Keep the editor contents; nothing is written to disk")
    (my-disk-later "Later" "Later" "l" "Hide this notice; the mode line keeps the indicator"))
  "(COMMAND LABEL SHORT-LABEL KEY HELP) for each notification action.")

(defun my-disk-available-actions ()
  "Actions for the pending change; a missing file cannot be compared or reloaded."
  (if (eq (plist-get my-disk-pending :hash) 'missing)
      (seq-filter (lambda (action) (memq (car action) '(my-disk-keep my-disk-later))) my-disk-actions)
    my-disk-actions))

(defun my-disk-message ()
  "The full sentence describing the pending change."
  (let ((name (my-disk-name)) (new (if (plist-get my-disk-pending :again) "new " "")))
    (cond ((eq (plist-get my-disk-pending :hash) 'missing)
           (format "%s was deleted or cannot be read. The editor contents are kept." name))
          ((buffer-modified-p)
           (format "%s has %sexternal changes. Your editor has unsaved changes." name new))
          (t (format "%s has %sexternal changes." name new)))))

(defun my-disk-action-buttons (short)
  (mapconcat (pcase-lambda (`(,command ,label ,short-label ,key ,help))
               (propertize (my-disk-button (format "[%s]" (if short short-label label))
                                           (format "%s: %s (C-c d %s)" label help key) command)
                           'my-disk-action command))
             (my-disk-available-actions) " "))

(defun my-disk-header-line (&optional width)
  "A one-line notice whose actions stay visible within WIDTH columns."
  (let* ((width (or width (window-width)))
         (missing (eq (plist-get my-disk-pending :hash) 'missing))
         (help (concat (my-disk-message) "\nAll actions: C-c d m"))
         (title (propertize (if missing " Missing on disk " " Changed on disk ")
                            'face 'warning 'help-echo help))
         (state (cond (missing " (deleted)")
                      ((buffer-modified-p) " (unsaved edits)")
                      (t "")))
         (menu (propertize (my-disk-button "[Actions]" (concat help "\nmouse-1: choose an action")
                                           #'my-disk-choose)
                           'my-disk-action 'my-disk-choose))
         ;; Full labels, then short ones, then only the menu: never clip an action.
         (actions (seq-find (lambda (text) (<= (+ (string-width title) 8 (string-width state)
                                                   (string-width text) 3)
                                                width))
                            (list (my-disk-action-buttons nil) (my-disk-action-buttons t))
                            menu))
         (room (- width (string-width title) (string-width actions) 3))
         (name (my-disk-name)))
    (when (< (- room (string-width state)) 6) (setq state ""))
    (concat title " "
            (propertize (concat (truncate-string-to-width name (max 1 (- room (string-width state)))
                                                          nil nil "…")
                                state)
                        'help-echo help)
            "  " actions)))

(defun my-disk-choose ()
  "Choose any action for the current buffer's disk change from a menu."
  (interactive)
  (unless my-disk-pending (user-error "%s has no unreviewed disk changes" (my-disk-name)))
  (popup-menu (cons (my-disk-message)
                    (mapcar (pcase-lambda (`(,command ,label ,_ ,key ,_))
                              (vector label command :keys (concat "C-c d " key)))
                            (my-disk-available-actions)))
              (if (mouse-event-p last-nonmenu-event) last-nonmenu-event (or (posn-at-point) t))))

(defun my-disk-show-header ()
  (unless my-disk-saved-header
    (setq my-disk-saved-header (cons (local-variable-p 'header-line-format) header-line-format)))
  (setq-local header-line-format '(:eval (my-disk-header-line))))

(defun my-disk-hide-header ()
  (when my-disk-saved-header
    (if (car my-disk-saved-header)
        (setq header-line-format (cdr my-disk-saved-header))
      (kill-local-variable 'header-line-format))
    (setq my-disk-saved-header nil)))

(defun my-disk-mode-line ()
  (when my-disk-pending
    (my-disk-button (propertize (if (eq (plist-get my-disk-pending :hash) 'missing)
                                    " Missing on disk " " Changed on disk ")
                                'face 'warning)
                    "mouse-1: review the disk change (C-c d d)" #'my-disk-review)))

(add-to-list 'mode-line-misc-info '(:eval (my-disk-mode-line)))

;;; Actions

(defun my-disk-reviewed ()
  "Return (HASH BYTES META) when the disk still holds the version under review.
Otherwise refresh the notification and any comparison, and return nil."
  (unless (my-disk-covered-p) (user-error "This buffer does not visit a local file"))
  ;; Taken before rechecking, so a write noticed now is never applied unseen.
  (let ((reviewed (if (buffer-live-p (plist-get my-disk-compare :control))
                      (plist-get my-disk-compare :hash)
                    (plist-get my-disk-pending :hash))))
    (my-disk-check)
    (unless my-disk-pending (user-error "%s has no unreviewed disk changes" (my-disk-name)))
    (let ((disk (my-disk-read)))
      (if (equal (car disk) reviewed)
          disk
        (when (buffer-live-p (plist-get my-disk-compare :control)) (my-disk-compare))
        (message "%s changed again on disk. Review the new version first." (my-disk-name))
        nil))))

(defun my-disk-save-recovery ()
  "Copy the editor text to a new file and return its name."
  (make-directory my-disk-recovery-directory t)
  (let ((file (make-temp-file (expand-file-name (concat (my-disk-name) ".")
                                                my-disk-recovery-directory)
                              nil (format-time-string ".%Y%m%d-%H%M%S")))
        (coding-system-for-write (or buffer-file-coding-system 'utf-8-unix)))
    (write-region nil nil file nil 'silent)
    file))

(defun my-disk-reload ()
  "Replace the editor contents with the reviewed disk version."
  (interactive)
  (when-let* ((disk (my-disk-reviewed)))
    (unless (cadr disk) (user-error "%s cannot be read from disk" (my-disk-name)))
    (when (and (buffer-modified-p)
               (not (y-or-n-p (format "Discard unsaved changes in %s and reload from disk? A recovery copy is saved first. "
                                      (my-disk-name)))))
      (user-error "Reload canceled"))
    ;; The prompt may have taken a while; another write must be reviewed first.
    (when-let* ((disk (my-disk-reviewed)))
      (let ((recovery (and (buffer-modified-p) (my-disk-save-recovery))))
        (if (not (equal (my-disk-meta buffer-file-name) (nth 2 disk)))
            ;; Written during the recovery copy: leave the editor as it is.
            (progn (my-disk-check)
                   (message "%s changed again on disk. Review the new version first.%s" (my-disk-name)
                            (if recovery (format " Unsaved changes were also copied to %s" recovery) "")))
          (my-disk-apply disk)
          (message (if recovery (format "Reloaded %s. Unsaved changes were copied to %s"
                                        (my-disk-name) recovery)
                     (format "Reloaded %s from disk." (my-disk-name)))))))))

(defun my-disk-apply (disk)
  "Replace the editor text with the verified bytes of DISK, as a revert would.
Nothing is read again, so an unseen write cannot slip in."
  (let ((windows (mapcar (lambda (window) (list window (window-start window) (window-point window)))
                         (get-buffer-window-list nil nil t)))
        (source (current-buffer))
        (text (decode-coding-string (cadr disk) (or buffer-file-coding-system 'utf-8-unix))))
    (let ((revert-buffer-in-progress t)
          (revert-buffer-preserve-modes t)
          (inhibit-read-only t))
      (run-hooks 'before-revert-hook)
      (save-restriction
        (widen)
        (with-temp-buffer
          (insert text)
          (let ((temp (current-buffer)))
            (with-current-buffer source
              ;; Without a truename, editing skips the lock's supersession prompt.
              (unless (let ((buffer-file-truename nil)) (replace-region-contents (point-min) (point-max) temp 1.0))
                ;; Fell back to a wholesale replacement: put windows back by position.
                (pcase-dolist (`(,window ,start ,point) windows)
                  (set-window-start window (min start (point-max)) t)
                  (set-window-point window (min point (point-max)))))))))
      ;; The version applied, so a later write is still detected and still guarded.
      (set-visited-file-modtime (car (nth 2 disk)))
      (set-buffer-modified-p nil)
      (run-hooks 'after-revert-hook))))

(defun my-disk-keep ()
  "Keep the editor contents and stop notifying about the reviewed disk version."
  (interactive)
  (when-let* ((disk (my-disk-reviewed)))
    (setq my-disk-ack (car disk))
    ;; The supersession check still asks before a later save overwrites the file.
    (unless (my-disk-same-as-editor-p (cadr disk))
      ;; Without a truename, marking skips the lock's own supersession prompt.
      (let ((buffer-file-truename nil)) (set-buffer-modified-p t)))
    (my-disk-resolve)
    (message "Kept the editor version of %s. Nothing was written to disk." (my-disk-name))))

(defun my-disk-later ()
  "Hide the notification, keeping the mode-line indicator."
  (interactive)
  (when my-disk-pending
    (plist-put my-disk-pending :expanded nil)
    (my-disk-hide-header)))

(defun my-disk-review ()
  "Show the notification for the current buffer's disk change again."
  (interactive)
  (my-disk-check)
  (if (not my-disk-pending)
      (message "%s has no unreviewed disk changes." (my-disk-name))
    (plist-put my-disk-pending :expanded t)
    (my-disk-show-header)))

;;; Comparison

(defun my-disk-snapshot (label text mode source hash)
  "Return a read-only buffer named after LABEL holding TEXT in MODE."
  (with-current-buffer (generate-new-buffer
                        (format "*%s: %s*" label (with-current-buffer source (my-disk-name))))
    (insert text)
    ;; Mode hooks would start language servers for a buffer without a file.
    (condition-case nil (delay-mode-hooks (funcall mode)) (error (fundamental-mode)))
    (font-lock-mode 1)
    (setq my-disk-source source my-disk-snapshot-label label my-disk-snapshot-hash hash
          buffer-read-only t)
    (setq-local header-line-format '(:eval (my-disk-snapshot-header)))
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (current-buffer)))

(defun my-disk-snapshot-header ()
  (concat " " (propertize my-disk-snapshot-label 'face 'bold)
          (and my-disk-snapshot-hash (buffer-live-p my-disk-source)
               (not (equal my-disk-snapshot-hash
                           (plist-get (buffer-local-value 'my-disk-pending my-disk-source) :hash)))
               (propertize "  Outdated: the file changed again on disk" 'face 'warning))
          (propertize "   n/p: next/previous difference   q: return to the editor" 'face 'shadow)))

(defun my-disk-compare ()
  "Compare read-only snapshots of the editor and disk versions side by side."
  (interactive)
  (unless (my-disk-covered-p) (user-error "This buffer does not visit a local file"))
  (my-disk-check)
  (let* ((source (current-buffer))
         (disk (my-disk-read))
         (old (plist-get my-disk-compare :control)))
    (unless (cadr disk) (user-error "%s cannot be read from disk" (my-disk-name)))
    ;; Replace an open comparison instead of nesting another layout over it.
    (when (buffer-live-p old)
      (with-current-buffer old (ediff-really-quit nil)))
    (let* ((config (current-window-configuration))
           (editor (my-disk-snapshot "Editor Version" (my-disk-editor-text) major-mode source nil))
           (snapshot (my-disk-snapshot "Disk Version"
                                       (decode-coding-string (cadr disk) (or buffer-file-coding-system 'utf-8-unix))
                                       major-mode source (car disk)))
           (ediff-window-setup-function #'ediff-setup-windows-plain)
           (ediff-split-window-function #'split-window-horizontally))
      (ediff-buffers
       editor snapshot
       (list (lambda ()
               (let ((control (current-buffer)))
                 (setq-local ediff-keep-variants t
                             ediff-window-setup-function #'ediff-setup-windows-plain
                             ediff-split-window-function #'split-window-horizontally)
                 (with-current-buffer source
                   (setq my-disk-compare (list :control control :hash (car disk))))
                 (add-hook 'ediff-after-quit-hook-internal
                           (lambda ()
                             (mapc #'kill-buffer (seq-filter #'buffer-live-p (list editor snapshot)))
                             (when (buffer-live-p source)
                               (with-current-buffer source (setq my-disk-compare nil)))
                             (set-window-configuration config))
                           nil t))))))))

;;; Wiring

(defconst my-disk-map
  (let ((map (make-sparse-keymap)))
    (define-key map "c" #'my-disk-compare)
    (define-key map "r" #'my-disk-reload)
    (define-key map "k" #'my-disk-keep)
    (define-key map "l" #'my-disk-later)
    (define-key map "d" #'my-disk-review)
    (define-key map "m" #'my-disk-choose)
    map))
(global-set-key (kbd "C-c d") my-disk-map)

;; Visiting a changed file reuses its buffer; the notification replaces the prompt.
(setq query-about-changed-file nil)
(advice-add 'auto-revert-handler :around #'my-disk-auto-revert)
(add-hook 'first-change-hook #'my-disk-record-baseline)
(add-hook 'after-save-hook #'my-disk-reset)
(add-hook 'after-revert-hook #'my-disk-reset)
(add-hook 'window-buffer-change-functions #'my-disk-schedule)
(add-hook 'window-selection-change-functions #'my-disk-schedule)
(add-hook 'tab-bar-tab-post-select-functions #'my-disk-schedule)
(remove-function after-focus-change-function #'my-disk-schedule)
(add-function :after after-focus-change-function #'my-disk-schedule)
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (and (buffer-modified-p) (not my-disk-baseline)) (my-disk-record-baseline))))

(provide 'my-disk-changes)
;;; disk-changes.el ends here
