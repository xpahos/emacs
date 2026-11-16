;;; project-search.el --- Responsive project file selection -*- lexical-binding: t; -*-

(require 'tab-bar)
(require 'icomplete)
(require 'find-dired)
(require 'cl-lib)

(defvar my-project-search-history nil)

(defun my-project-search-source (root)
  "Return (BASE PROGRAM . ARGS) for listing files below ROOT."
  (let ((copies (directory-file-name (expand-file-name "worktree" user-emacs-directory))))
    (cons root (append (list find-program "-H" (file-local-name root))
                       ;; Generated working copies of other projects are not part of this one.
                       (when (file-in-directory-p copies root)
                         (list "-path" (file-local-name copies) "-prune" "-o"))
                       (list "-type" "d" "-name" ".git" "-prune" "-o" "-type" "f" "-print0")))))

(defun my-project-read-file (root)
  "Choose a file under ROOT while a fresh file list is loaded asynchronously."
  (let* ((source (my-project-search-source root))
         (default-directory (car source))
         (completion-styles '(substring))
         (completion-category-defaults nil)
         (completion-category-overrides nil)
         (icomplete-mode t)
         (icomplete-vertical-mode t)
         (icomplete-show-matches-on-no-input nil)
         (icomplete-minibuffer-setup-hook '(icomplete--vertical-minibuffer-setup))
         (active t)
         (pending "")
         ready files process errors minibuffer failure selected refresh refresh-timer dirty)
    (unwind-protect
        (progn
          (setq errors (generate-new-buffer " *project-files-errors*")
                refresh
                (lambda ()
                  (when (and active dirty (buffer-live-p minibuffer)
                             (active-minibuffer-window)
                             (eq (window-buffer (active-minibuffer-window)) minibuffer))
                    (setq dirty nil)
                    (with-selected-window (active-minibuffer-window)
                      (setq completion-all-sorted-completions nil)
                      (if failure (exit-minibuffer) (icomplete-exhibit)))))
                refresh-timer (run-at-time 0.1 0.1 refresh))
          (setq process
                (make-process
                 :name "project-files" :buffer nil :stderr errors
                 :command (cdr source) :connection-type 'pipe :noquery t :file-handler t
                 :filter
                 (lambda (_proc chunk)
                   ;; Arc directory walks can be slow; offer complete paths as they arrive.
                   (setq pending (concat pending chunk))
                   (when-let* ((end (cl-position 0 pending :from-end t)))
                     (setq files (nconc (split-string (substring pending 0 end) "\0" t) files)
                           pending (substring pending (1+ end))
                           dirty t)))
                 :sentinel
                 (lambda (proc _event)
                   (when (and active (memq (process-status proc) '(exit signal)))
                     (setq ready t dirty t)
                     (unless (zerop (process-exit-status proc))
                       (unless failure
                         (setq failure (format "File indexing failed (exit %s): %s"
                                               (process-exit-status proc)
                                               (with-current-buffer errors
                                                 (string-trim (buffer-string)))))))
                     (funcall refresh)))))
          (setq selected
                (minibuffer-with-setup-hook
                    (lambda ()
                      (setq minibuffer (current-buffer))
                      (icomplete-minibuffer-setup)
                      (use-local-map (copy-keymap (current-local-map)))
                      (local-set-key
                       (kbd "RET")
                       (lambda ()
                         (interactive)
                         (if (or ready files)
                             (icomplete-force-complete-and-exit)
                           (minibuffer-message "Indexing project files…")))))
                  (completing-read
                   (format "Find file in %s: " (file-name-nondirectory (directory-file-name root)))
                   (lambda (string predicate action)
                     (if (eq action 'metadata)
                         '(metadata (category . project-file))
                       (complete-with-action action files string predicate)))
                   nil t nil 'my-project-search-history)))
          (when failure (user-error "%s" failure))
          (unless (and (not (string-empty-p selected)) (member selected files))
            (user-error "Select a file from the results"))
          (expand-file-name selected default-directory))
      (setq active nil)
      (when (timerp refresh-timer) (cancel-timer refresh-timer))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p errors) (kill-buffer errors)))))

(defun my-project-find-file ()
  "Find a file under the tab's folder or current directory using a fresh list."
  (interactive)
  (let* ((root (or (alist-get 'my-project-root (tab-bar--current-tab)) default-directory))
         (editor (if (window-parameter (selected-window) 'window-side)
                     (seq-find (lambda (w) (not (window-dedicated-p w))) (window-list))
                   (selected-window)))
         file)
    (setq file (save-window-excursion (my-project-read-file root)))
    (unless (and (stringp file) (not (string-empty-p file)) (file-regular-p file))
      (user-error "Select an existing file, not a directory"))
    (when (window-live-p editor) (select-window editor))
    (find-file file)))

(global-set-key (kbd "C-c p o") #'my-project-find-file)
(provide 'my-project-search)
