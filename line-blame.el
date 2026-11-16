;;; line-blame.el --- Inline blame annotations for Arc and Git -*- lexical-binding: t; -*-

;; Annotations are display-only `line-prefix' overlays: they appear right after
;; native line numbers, stay put under horizontal scrolling and never touch the
;; buffer text, undo history or modified flag.

(require 'cl-lib)
(require 'subr-x)
(require 'vc-git)

(declare-function vc-arc-root "vc-arc" (file))
(defvar arcit-arc-executable)

(defface line-blame '((t :inherit line-number))
  "Face for blame annotations." :group 'vc)

(defvar line-blame-author-width 16
  "Maximum author width; longer names are truncated.")

(defvar-local line-blame--request nil
  "Token of the pending request: a one-element list holding its live process.")
(defvar-local line-blame--overlays nil)

;;; Parsing

(defun line-blame--parse-arc (output)
  "Return (DATE . AUTHOR) per line from Arc `blame --json' OUTPUT; AUTHOR is a login."
  (mapcar (lambda (entry)
            (let ((date (alist-get 'date entry)))
              (cons (format "%s.%s.%s" (substring date 8 10) (substring date 5 7)
                            (substring date 0 4))
                    (alist-get 'author entry))))
          (sort (alist-get 'annotation (json-parse-string output :object-type 'alist
                                                          :array-type 'list))
                (lambda (a b) (< (alist-get 'line a) (alist-get 'line b))))))

(defun line-blame--parse-git (output)
  "Return (DATE . AUTHOR) per line from `git blame --line-porcelain' OUTPUT.
AUTHOR is the local part of the author's email, or their name without one."
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let (entries author login time zone)
      (while (not (eobp))
        (cond ((eq (char-after) ?\t)
               (push (cons (format-time-string "%d.%m.%Y" time zone) (or login author))
                     entries))
              ((looking-at "author \\(.*\\)")
               (setq author (match-string 1) login nil))
              ((looking-at "author-mail <\\([^@> \t]+\\)@")
               (setq login (match-string 1)))
              ((looking-at "author-time \\([0-9]+\\)")
               (setq time (string-to-number (match-string 1))))
              ((looking-at "author-tz \\([-+]\\)\\([0-9][0-9]\\)\\([0-9][0-9]\\)")
               ;; Show the author's own calendar date, as Arc does.
               (setq zone (* (if (equal (match-string 1) "-") -1 1)
                             (+ (* 3600 (string-to-number (match-string 2)))
                                (* 60 (string-to-number (match-string 3))))))))
        (forward-line 1))
      (nreverse entries))))

(defun line-blame--dirty-reason (backend status)
  "Return why STATUS output shows the file differs from HEAD, or nil."
  (if (eq backend 'Arc)
      (let ((status (alist-get 'status (json-parse-string status :object-type 'alist))))
        (cond ((alist-get 'untracked status) "the file is not tracked")
              ((alist-get 'ignored status) "the file is ignored")
              (status "the file has uncommitted changes")))
    (cond ((string-prefix-p "??" status) "the file is not tracked")
          ((string-prefix-p "!!" status) "the file is ignored")
          ((not (string-empty-p status)) "the file has uncommitted changes"))))

;;; Processes

(defun line-blame--fail (text)
  (line-blame-mode -1)
  (message "Blame unavailable: %s" text))

(defun line-blame--run (token program args callback)
  "Run PROGRAM ARGS; pass stdout to CALLBACK in this buffer while TOKEN is current."
  (let* ((buffer (current-buffer))
         (out (generate-new-buffer " *line-blame*"))
         (err (generate-new-buffer " *line-blame-err*"))
         (process
          (make-process
           :name "line-blame" :buffer out :stderr err :noquery t
           :connection-type 'pipe :coding 'utf-8 :command (cons program args)
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (unwind-protect
                   (when (and (buffer-live-p buffer)
                              (eq token (buffer-local-value 'line-blame--request buffer)))
                     ;; Stderr arrives on its own pipe; drain it before reporting.
                     (when-let* ((pipe (get-buffer-process err)))
                       (while (accept-process-output pipe 0.05)))
                     (let ((stdout (with-current-buffer out (buffer-string)))
                           (stderr (string-trim (with-current-buffer err (buffer-string)))))
                       (with-current-buffer buffer
                         (if (and (eq (process-status process) 'exit)
                                  (zerop (process-exit-status process)))
                             (condition-case failure (funcall callback stdout)
                               (error (line-blame--fail (error-message-string failure))))
                           (line-blame--fail
                            (format "%s %s failed: %s" (file-name-nondirectory program)
                                    (car args)
                                    (if (string-empty-p stderr)
                                        (format "exit status %s" (process-exit-status process))
                                      stderr)))))))
                 (kill-buffer out)
                 (kill-buffer err)))))))
    (when-let* ((pipe (get-buffer-process err)))
      (set-process-query-on-exit-flag pipe nil))
    (setcar token process)))

(defun line-blame--start ()
  "Fetch blame for the whole file asynchronously, then render it."
  (let* ((file (or buffer-file-name (user-error "Blame needs a file buffer")))
         (_ (when (file-remote-p file) (user-error "Blame does not support remote files")))
         (_ (when (buffer-modified-p)
              (user-error "Blame unavailable: the buffer has unsaved changes")))
         (arc (vc-arc-root file))
         (root (or arc (vc-git-root file)
                   (user-error "Blame unavailable: not in an Arc or Git repository")))
         (backend (if arc 'Arc 'Git))
         (program (if arc arcit-arc-executable vc-git-program))
         (path (file-relative-name file root))
         (token (list nil)))
    (cl-flet ((run (args callback)
                (let ((default-directory root))
                  (line-blame--run token program args callback))))
      (setq line-blame--request token)
      (add-hook 'first-change-hook #'line-blame--edited nil t)
      (add-hook 'after-revert-hook #'line-blame--edited nil t)
      (add-hook 'kill-buffer-hook #'line-blame--cleanup nil t)
      ;; Runs before local variables, including the overlay list, are reset.
      (add-hook 'change-major-mode-hook #'line-blame--cleanup nil t)
      (run '("rev-parse" "HEAD")
           (lambda (output)
             (let ((head (string-trim output)))
               (run (if arc `("status" "--json" "--ignored" "--" ,path)
                      `("status" "--porcelain" "--ignored" "--" ,path))
                    (lambda (status)
                      (if-let* ((reason (line-blame--dirty-reason backend status)))
                          (line-blame--fail reason)
                        (run (if arc `("blame" "--json" ,head ,path)
                               `("blame" "--line-porcelain" ,head "--" ,path))
                             (lambda (output)
                               (let ((entries (if arc (line-blame--parse-arc output)
                                                (line-blame--parse-git output))))
                                 ;; Discard blame for a revision that is no longer checked out.
                                 (run '("rev-parse" "HEAD")
                                      (lambda (now)
                                        (cond
                                         ((not (equal (string-trim now) head))
                                          (line-blame--fail "HEAD changed while loading"))
                                         ((not (verify-visited-file-modtime))
                                          (line-blame--fail "the file changed on disk"))
                                         (t (line-blame--render entries))))))))))))))
      (message "Loading blame..."))))

;;; Display

(defun line-blame--render (entries)
  (save-excursion
    (save-restriction
      (widen)
      (unless (= (length entries) (count-lines (point-min) (point-max)))
        (error "blame does not match the buffer contents"))
      (let* ((width (min line-blame-author-width
                         (apply #'max 0 (mapcar (lambda (e) (string-width (cdr e))) entries))))
             ;; "│ DD.MM.YYYY  AUTHOR │ ": separators after line numbers and before code.
             (blank (propertize (make-string (+ 2 10 2 width 3) ?\s) 'face 'line-blame)))
        (goto-char (point-min))
        (dolist (entry entries)
          (let ((overlay (make-overlay (point) (progn (forward-line 1) (point)))))
            (overlay-put overlay 'line-prefix
                         (propertize (concat "│ " (car entry) "  "
                                             (truncate-string-to-width
                                              (cdr entry) width nil ?\s "…")
                                             " │ ")
                                     'face 'line-blame))
            (overlay-put overlay 'wrap-prefix blank)
            (push overlay line-blame--overlays))))))
  (setq line-blame--request nil)
  (message "Loading blame...done"))

(defun line-blame--cleanup ()
  "Cancel pending work and remove annotations."
  (let ((process (car line-blame--request)))
    ;; Invalidate first: `delete-process' runs the sentinel synchronously.
    (setq line-blame--request nil)
    (when process (delete-process process)))
  (mapc #'delete-overlay line-blame--overlays)
  (setq line-blame--overlays nil)
  (remove-hook 'first-change-hook #'line-blame--edited t)
  (remove-hook 'after-revert-hook #'line-blame--edited t)
  (remove-hook 'kill-buffer-hook #'line-blame--cleanup t)
  (remove-hook 'change-major-mode-hook #'line-blame--cleanup t))

(defun line-blame--edited ()
  (line-blame-mode -1)
  (message "Blame hidden: the buffer no longer matches HEAD"))

;;;###autoload
(define-minor-mode line-blame-mode
  "Show the date and author of the last change before each line."
  :lighter nil
  (line-blame--cleanup)
  (when line-blame-mode
    (condition-case err
        (line-blame--start)
      (error (line-blame--cleanup)
             (setq line-blame-mode nil)
             (signal (car err) (cdr err))))))

(provide 'line-blame)
;;; line-blame.el ends here
