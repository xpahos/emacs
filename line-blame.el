;;; line-blame.el --- Inline blame annotations for Arc and Git -*- lexical-binding: t; -*-

;; Annotations are display-only `line-prefix' overlays: they appear right after
;; native line numbers, stay put under horizontal scrolling and never touch the
;; buffer text, undo history or modified flag.

(require 'cl-lib)
(require 'color)
(require 'subr-x)
(require 'vc-git)
(require 'my-popup-style (expand-file-name "popup-style.el"
                                          (file-name-directory load-file-name)))

(declare-function vc-arc-root "vc-arc" (file))
(defvar arcit-arc-executable)

(defface line-blame '((t :inherit line-number))
  "Face for blame annotations." :group 'vc)

(defvar line-blame-author-width 16
  "Maximum author width; longer names are truncated.")

(defvar-local line-blame--request nil
  "Token of the pending request: a one-element list holding its live process.")
(defvar-local line-blame--overlays nil)
(defvar-local line-blame--root nil "Repository root, part of the commit cache key.")

(defvar line-blame-hover-delay 0.4
  "Seconds the pointer must rest on an annotation before commit details appear.")

;;; Parsing

(defun line-blame--with-review (message review)
  "Append REVIEW to MESSAGE unless it is absent or MESSAGE already names it."
  (if (or (null review) (string-match-p (concat "REVIEW: *" (regexp-quote review)) message))
      message
    (concat message "\n\nREVIEW: " review)))

(defun line-blame--parse-arc (output)
  "Return (DATE AUTHOR COMMIT TIME MESSAGE) per line of Arc `blame --json' OUTPUT.
AUTHOR is the Arc login.  Arc includes full messages, so none is fetched later."
  (let* ((json (json-parse-string output :object-type 'alist :array-type 'list))
         (messages (make-hash-table :test #'equal)))
    (dolist (commit (alist-get 'commits json))
      (puthash (alist-get 'commit commit)
               (line-blame--with-review
                (string-trim-right (or (alist-get 'message commit) ""))
                (alist-get 'pr.id (alist-get 'attributes commit)))
               messages))
    (mapcar (lambda (entry)
              (let ((date (alist-get 'date entry)) (commit (alist-get 'commit entry)))
                (list (format "%s.%s.%s" (substring date 8 10) (substring date 5 7)
                              (substring date 0 4))
                      (alist-get 'author entry) commit
                      (format "%s.%s.%s, %s" (substring date 8 10) (substring date 5 7)
                              (substring date 0 4) (substring date 11 16))
                      (gethash commit messages ""))))
            (sort (alist-get 'annotation json)
                  (lambda (a b) (< (alist-get 'line a) (alist-get 'line b)))))))

(defun line-blame--parse-git (output)
  "Return (DATE AUTHOR COMMIT TIME nil) per line of Git porcelain blame OUTPUT.
AUTHOR is the local part of the author's email, or their name without one.
Porcelain output has only the summary, so messages are fetched on hover."
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let (entries commit author login time zone)
      (while (not (eobp))
        (cond ((eq (char-after) ?\t)
               (push (list (format-time-string "%d.%m.%Y" time zone) (or login author)
                           commit (format-time-string "%d.%m.%Y, %H:%M" time zone) nil)
                     entries))
              ((looking-at "\\([0-9a-f]\\{40,64\\}\\) [0-9]+ [0-9]+")
               (setq commit (match-string 1)))
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
      (setq line-blame--request token
            line-blame--root root)
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

(defun line-blame--day (date)
  "Return a day number for DATE, a DD.MM.YYYY string."
  (/ (time-convert (encode-time (list 0 0 0 (string-to-number (substring date 0 2))
                                      (string-to-number (substring date 3 5))
                                      (string-to-number (substring date 6 10)) nil nil 0))
                   'integer)
     86400))

(defun line-blame--shade (day first last)
  "Return 0 (oldest) to 4 (newest) for DAY within FIRST..LAST, in equal slices."
  (/ (* 5 (- day first)) (1+ (- last first))))

(defun line-blame--shade-faces ()
  "Return five backgrounds from the theme's annotation color, darkest for newest."
  (let ((background (face-background 'line-blame nil t)))
    (mapcar (lambda (step)
              (and (color-defined-p background)
                   `(:background ,(color-darken-name background (* 3 step)))))
            '(0 1 2 3 4))))

(defun line-blame--render (entries)
  (save-excursion
    (save-restriction
      (widen)
      (unless (= (length entries) (count-lines (point-min) (point-max)))
        (error "blame does not match the buffer contents"))
      (let* ((width (min line-blame-author-width
                         (apply #'max 0 (mapcar (lambda (e) (string-width (nth 1 e))) entries))))
             (days (mapcar (lambda (e) (line-blame--day (car e))) entries))
             (first (and days (apply #'min days)))
             (last (and days (apply #'max days)))
             (shades (line-blame--shade-faces))
             ;; "│ DD.MM.YYYY  AUTHOR │ ": separators after line numbers and before code.
             (blank (propertize (make-string (+ 2 10 2 width 3) ?\s) 'face 'line-blame)))
        (goto-char (point-min))
        (cl-loop
         for entry in entries for day in days do
         (let ((overlay (make-overlay (point) (progn (forward-line 1) (point)))))
           (overlay-put overlay 'line-prefix
                        (concat (propertize "│ " 'face 'line-blame)
                                ;; Only date and nickname are shaded and hoverable.
                                (propertize (concat (car entry) "  "
                                                    (truncate-string-to-width
                                                     (nth 1 entry) width nil ?\s "…"))
                                            'face (list (nth (line-blame--shade day first last)
                                                             shades)
                                                        'line-blame)
                                            'line-blame-entry entry)
                                (propertize " │ " 'face 'line-blame)))
           (overlay-put overlay 'wrap-prefix blank)
           (push overlay line-blame--overlays))))))
  (when line-blame--overlays (line-blame--watch-pointer))
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
  (line-blame--unwatch-pointer)
  (remove-hook 'first-change-hook #'line-blame--edited t)
  (remove-hook 'after-revert-hook #'line-blame--edited t)
  (remove-hook 'kill-buffer-hook #'line-blame--cleanup t)
  (remove-hook 'change-major-mode-hook #'line-blame--cleanup t))

(defun line-blame--edited ()
  (line-blame-mode -1)
  (message "Blame hidden: the buffer no longer matches HEAD"))

;;; Commit details on hover

(defvar line-blame--messages (make-hash-table :test #'equal)
  "Commit messages keyed by (ROOT . COMMIT); a failure is stored as (error . TEXT).")
(defvar line-blame--fetching (make-hash-table :test #'equal)
  "Keys whose message is being fetched.")
(defvar line-blame--buffers nil "Buffers showing annotations.")
(defvar line-blame--poll-timer nil)
(defvar line-blame--target nil
  "Annotation under the pointer: (WINDOW PREFIX LEFT . TOP).
LEFT and TOP are the tooltip's screen position.")
(defvar line-blame--delay-timer nil)
(defvar line-blame--shown nil "Target whose tooltip is visible.")

(defun line-blame--same-target-p (a b)
  "Non-nil when A and B are the same line in the same window."
  (and a b (eq (car a) (car b)) (eq (cadr a) (cadr b))))

(defun line-blame--target-at-mouse ()
  "Return the annotation target under the pointer, or nil."
  (pcase-let ((`(,frame ,x . ,y) (mouse-pixel-position)))
    (when (and (frame-live-p frame) (natnump x) (natnump y))
      (let* ((posn (posn-at-x-y x y frame))
             (window (posn-window posn)))
        (when (and (windowp window) (null (posn-area posn)) (posn-point posn)
                   (buffer-local-value 'line-blame--overlays (window-buffer window)))
          ;; `posn-string' misplaces line prefixes under hscroll, so find the
          ;; row through `posn-point' and the column from the pixel offset.
          (with-selected-window window
            (save-excursion
              (goto-char (posn-point posn))
              (vertical-motion 0)
              (let* ((prefix (get-char-property (point) 'line-prefix))
                     (width (window-font-width))
                     (start (+ (nth 0 (window-inside-pixel-edges))
                               (line-number-display-width t)))
                     (column (/ (- x start) width)))
                ;; Continuation rows start mid-line and show the blank wrap prefix.
                (when (and (bolp) (stringp prefix) (>= x start)
                           (< column (string-width prefix))
                           (get-text-property (length (truncate-string-to-width
                                                       prefix column))
                                              'line-blame-entry prefix))
                  (let ((edges (frame-edges frame 'inner-edges)))
                    ;; Open the tooltip right of the annotation and below its row,
                    ;; so the pointer leaves the annotation, hiding the tip, first.
                    (cl-list* window prefix
                              (+ (nth 0 edges) start (* width (string-width prefix)))
                              (+ (nth 1 edges) (- y (cdr (posn-object-x-y posn)))
                                 (cdr (posn-object-width-height posn))))))))))))))

(defun line-blame--hide ()
  (when line-blame--delay-timer
    (cancel-timer line-blame--delay-timer)
    (setq line-blame--delay-timer nil))
  (when line-blame--shown
    (setq line-blame--shown nil)
    (posframe-hide " *Blame details*")))

(defun line-blame--poll ()
  "Track the annotation under the pointer; restart the delay only when it changes."
  (let ((target (line-blame--target-at-mouse)))
    (unless (or (line-blame--same-target-p target line-blame--target)
                (and (null target) (null line-blame--target)))
      (line-blame--hide)
      (setq line-blame--target target)
      (when target
        (setq line-blame--delay-timer
              (run-with-timer line-blame-hover-delay nil #'line-blame--show))))))

(defun line-blame--watch-pointer ()
  (cl-pushnew (current-buffer) line-blame--buffers)
  ;; shortcut: polls the pointer 20 times a second while any annotation is shown;
  ;; move to mouse-movement events if this ever shows up in profiles.
  (unless line-blame--poll-timer
    (setq line-blame--poll-timer (run-with-timer 0.05 0.05 #'line-blame--poll))))

(defun line-blame--unwatch-pointer ()
  (line-blame--hide)
  (setq line-blame--target nil)
  (setq line-blame--buffers (cl-delete-if (lambda (b) (or (eq b (current-buffer))
                                                          (not (buffer-live-p b))))
                                          line-blame--buffers))
  (when (and line-blame--poll-timer (null line-blame--buffers))
    (cancel-timer line-blame--poll-timer)
    (setq line-blame--poll-timer nil)))

(defun line-blame--fill (text)
  "Wrap lines of TEXT longer than 72 columns, keeping its own line breaks."
  (with-temp-buffer
    (insert text)
    (let ((fill-column 72))
      (goto-char (point-min))
      (while (not (eobp))
        (when (> (- (line-end-position) (point)) fill-column)
          (fill-region (point) (line-end-position)))
        (forward-line 1)))
    (buffer-string)))

(defun line-blame--details (entry message)
  (concat "commit " (nth 2 entry) "\nAuthor: " (nth 1 entry) "\nDate: " (nth 3 entry)
          "\n\n"
          (if (eq (car-safe message) 'error)
              (concat "Commit message unavailable: " (cdr message))
            (line-blame--fill message))))

(defun line-blame--show ()
  "Show details for the current target, fetching its message first if needed."
  (setq line-blame--delay-timer nil)
  (when-let* ((target line-blame--target)
              (entry (get-text-property 2 'line-blame-entry (cadr target)))
              (buffer (window-buffer (car target)))
              (key (cons (buffer-local-value 'line-blame--root buffer) (nth 2 entry))))
    (if-let* ((message (or (nth 4 entry) (gethash key line-blame--messages))))
        (let ((edges (frame-edges (window-frame (car target)) 'inner-edges)))
          (my-popup-show " *Blame details*" (line-blame--details entry message)
                         (car target)
                         (cons (- (nth 2 target) (nth 0 edges))
                               (- (nthcdr 3 target) (nth 1 edges))))
          (setq line-blame--shown target))
      (line-blame--fetch key))))

(defun line-blame--fetch (key)
  "Fetch the Git message for KEY once, then show it if its line is still hovered."
  (unless (gethash key line-blame--fetching)
    (puthash key t line-blame--fetching)
    (let ((default-directory (car key))
          (out (generate-new-buffer " *line-blame-show*")))
      (make-process
       :name "line-blame-show" :buffer out :stderr out :noquery t
       :connection-type 'pipe :coding 'utf-8
       :command (list vc-git-program "-c" "log.showSignature=false"
                      "show" "-s" "--format=%B" (cdr key) "--")
       :sentinel
       (lambda (process _event)
         (unless (process-live-p process)
           (let ((text (string-trim (with-current-buffer out (buffer-string)))))
             (kill-buffer out)
             (remhash key line-blame--fetching)
             (puthash key (if (and (eq (process-status process) 'exit)
                                   (zerop (process-exit-status process)))
                              text
                            (cons 'error (if (string-empty-p text) "git show failed" text)))
                      line-blame--messages)
             ;; Only the line hovered now, after its delay, may show the result.
             (when (and line-blame--target (null line-blame--delay-timer)
                        (not line-blame--shown))
               (line-blame--show)))))))))

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
