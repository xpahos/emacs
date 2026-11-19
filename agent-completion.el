;;; agent-completion.el --- Floating / and @ completion in agent-shell -*- lexical-binding: t; -*-

;; Corfu replaces the *Completions* window only in agent-shell buffers.
;; Commands use agent-shell's CAPF; files stream from the folder picker's source.

(require 'corfu)
(require 'corfu-popupinfo)
(require 'agent-shell)
(require 'agent-shell-viewport)

(setq corfu-count 10
      corfu-preselect 'first
      corfu-preview-current nil
      corfu-quit-no-match nil
      corfu-popupinfo-delay '(0.4 . 0.2)
      corfu-popupinfo-direction '(right left vertical)
      corfu-border-width 2)
(corfu-popupinfo-mode 1)  ; global, but only acts where corfu-mode is on

(defun my-agent-completion-faces ()
  "Give the popups the shared tooltip background, border and padding."
  (let ((padding (/ 12.0 (default-font-width))))  ; my-popup-frame-parameters' 12px fringes
    (setq corfu-left-margin-width padding corfu-right-margin-width padding))
  (set-face-attribute 'corfu-default nil
                      :background (face-background 'tooltip nil t)
                      :foreground (face-foreground 'tooltip nil t))
  (set-face-attribute 'corfu-border nil
                      :background (face-background 'child-frame-border nil t))
  (set-face-attribute 'corfu-current nil
                      :background (face-background 'region nil t)
                      :foreground (face-foreground 'region nil t)
                      :extend t))
(my-agent-completion-faces)

(defun my-agent-completion-selected-row (_pos _off _width lines &optional current &rest _)
  "Keep match highlights readable on the selected row's dark background."
  (when-let* (((natnump current))
              (line (nth current lines)))
    (setq line (copy-sequence line))
    (add-face-text-property 0 (length line) 'corfu-current nil line)
    (setf (nth current lines) line)))
(advice-add 'corfu--popup-show :before #'my-agent-completion-selected-row)

(keymap-set corfu-map "TAB" #'corfu-insert)
(keymap-set corfu-map "<tab>" #'corfu-insert)
(keymap-set corfu-map "<escape>" #'corfu-quit)

;; Keep completion when Backspace removes the last character after / or @.
(dolist (command '(delete-backward-char backward-delete-char-untabify))
  (add-to-list 'corfu-continue-commands command))

(defun my-agent-completion-track-start (&rest _)
  "Follow the prompt when streaming output shifts the completion region."
  (when (and (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-edit-mode)
             (memq (char-before (car completion-in-region--data)) '(?/ ?@)))
    (setcar completion-in-region--data (copy-marker (car completion-in-region--data)))))
(advice-add 'corfu--setup :after #'my-agent-completion-track-start)

(defun my-agent-completion-range-valid-p (valid)
  "A tracked region ends when its / or @ trigger is deleted."
  (and valid
       (or (not (and (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-edit-mode)
                     (markerp (car completion-in-region--data))))
           (memq (char-before (car completion-in-region--data)) '(?/ ?@)))))
(advice-add 'corfu--range-valid-p :filter-return #'my-agent-completion-range-valid-p)

(defvar-local my-agent-file-table nil)
(defvar-local my-agent-file-cleanup nil)

(defun my-agent-files-stop ()
  "Stop the current file scan and discard its completion table."
  (when my-agent-file-cleanup (funcall my-agent-file-cleanup))
  (setq my-agent-file-cleanup nil my-agent-file-table nil)
  (remove-hook 'kill-buffer-hook #'my-agent-files-stop t)
  (remove-hook 'completion-in-region-mode-hook #'my-agent-files-ended t))

(defun my-agent-files-ended ()
  "Release the file scan when completion ends."
  (unless completion-in-region-mode (my-agent-files-stop)))

(defun my-agent-files-start (root)
  "Stream paths under ROOT into a completion table without blocking input."
  (let* ((source (my-project-search-source root))
         (default-directory (car source))
         (buffer (current-buffer))
         (pending "")
         (active t)
         (errors (generate-new-buffer " *agent-files-errors*"))
         files dirty process timer)
    (setq my-agent-file-table
          (lambda (string predicate action)
            (if (eq action 'metadata)
                ;; Keep arriving batches in order without re-sorting the whole tree.
                '(metadata (category . project-file) (display-sort-function . identity))
              (complete-with-action action files string predicate)))
          my-agent-file-cleanup
          (lambda ()
            (setq active nil)
            (when (timerp timer) (cancel-timer timer))
            (when (process-live-p process) (delete-process process))
            (when (buffer-live-p errors) (kill-buffer errors))))
    (add-hook 'kill-buffer-hook #'my-agent-files-stop nil t)
    (add-hook 'completion-in-region-mode-hook #'my-agent-files-ended nil t)
    (condition-case err
        (setq process
              (make-process
               :name "agent-files" :buffer nil :stderr errors :noquery t
               :command (cdr source) :connection-type 'pipe
               :filter
               (lambda (_process chunk)
                 (when active
                   (setq pending (concat pending chunk))
                   (when-let* ((end (cl-position 0 pending :from-end t)))
                     (setq files
                           (nconc files
                                  (mapcar (lambda (path) (string-remove-prefix root path))
                                          (split-string (substring pending 0 end) "\0" t)))
                           pending (substring pending (1+ end)) dirty t))))
               :sentinel
               (lambda (proc _event)
                 (when (and active (memq (process-status proc) '(exit signal))
                            (not (zerop (process-exit-status proc))))
                   (message "File completion failed (exit %s): %s"
                            (process-exit-status proc)
                            (with-current-buffer errors (string-trim (buffer-string))))))))
      (error (my-agent-files-stop) (signal (car err) (cdr err))))
    ;; Coalesce process chunks so a large folder does not redraw on every path.
    (setq timer
          (run-at-time
           0.1 0.1
           (lambda ()
             (when (and active dirty (waiting-for-user-input-p)
                        (not (input-pending-p)) (buffer-live-p buffer)
                        (eq buffer (window-buffer (selected-window))))
               (with-current-buffer buffer
                 (when (and completion-in-region-mode
                            (eq (nth 2 completion-in-region--data) my-agent-file-table))
                   (setq dirty nil corfu--input nil completion-all-sorted-completions nil)
                   (corfu--exhibit)))))))))

(defun my-agent-file-completion (original)
  "Use the folder picker's streaming source for local agent-shell completion."
  (if (not (and corfu-mode
                (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-edit-mode)
                (not (file-remote-p default-directory))))
      (funcall original)
    (when-let* ((bounds (agent-shell--completion-bounds "[:alnum:]/_.-" ?@))
                (source (agent-shell-completion--source-buffer)))
      (unless my-agent-file-table
        (my-agent-files-start
         (with-current-buffer source
           (file-name-as-directory
            (expand-file-name (if-let* ((project (project-current)))
                                  (project-root project)
                                default-directory))))))
      (list (map-elt bounds :start) (map-elt bounds :end) my-agent-file-table
            :exclusive t :company-prefix-length t
            :company-kind (lambda (_) 'file)
            :exit-function #'agent-shell--capf-exit-with-file-mention))))
(advice-add 'agent-shell--file-completion-at-point :around #'my-agent-file-completion)

(defun my-agent-files-capf (original function &optional prefix)
  "Let the streaming CAPF open before Corfu can find any candidates."
  (if (and (eq function #'agent-shell--file-completion-at-point)
           (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-edit-mode)
           (not (file-remote-p default-directory)))
      (when-let* ((capf (funcall function))) (cons function capf))
    (funcall original function prefix)))
(advice-add 'corfu--capf-wrapper :around #'my-agent-files-capf)

(defun my-agent-files-in-region (original beg end table predicate)
  "Open Corfu even while the first file results are still in flight."
  (if (and my-agent-file-table (eq table my-agent-file-table))
      (progn
        (unless completion-in-region-mode (corfu--setup beg end table predicate))
        t)
    (funcall original beg end table predicate)))
(advice-add 'corfu--in-region-1 :around #'my-agent-files-in-region)

(defun my-agent-command-doc (capf)
  "Cut CAPF's command descriptions to one line; the info popup shows them whole."
  (when-let* ((annotate (plist-get (nthcdr 3 capf) :annotation-function)))
    (setq capf (append (take 3 capf)
                       (list :annotation-function
                             (lambda (name)
                               (when-let* ((doc (funcall annotate name)))
                                 (concat "  " (truncate-string-to-width
                                               (car (split-string (string-trim doc) "\n")) 50 nil nil "…"))))
                             :company-doc-buffer
                             (lambda (name)
                               (when-let* ((doc (funcall annotate name)))
                                 (with-current-buffer (get-buffer-create " *agent-command-doc*")
                                   (erase-buffer)
                                   (insert (string-trim doc))
                                   (current-buffer)))))
                       (nthcdr 3 capf))))
  capf)
(advice-add 'agent-shell--command-completion-at-point :filter-return #'my-agent-command-doc)

(defun my-agent-completion-reposition (_frame)
  "Redraw an open popup at point after the frame or chat panel is resized."
  (when (and completion-in-region-mode (frame-live-p corfu--frame) (frame-visible-p corfu--frame))
    ;; Out of redisplay: child frames should not be moved from inside it.
    (run-at-time 0 nil (lambda ()
                         (with-current-buffer (window-buffer (selected-window))
                           (when (and corfu-mode completion-in-region-mode) (corfu--exhibit)))))))
(add-hook 'window-size-change-functions #'my-agent-completion-reposition)

(add-hook 'agent-shell-mode-hook #'corfu-mode)
(add-hook 'agent-shell-viewport-edit-mode-hook #'corfu-mode)

(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-edit-mode)
      (corfu-mode 1))))

(provide 'my-agent-completion)
;;; agent-completion.el ends here
