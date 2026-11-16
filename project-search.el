;;; project-search.el --- Responsive project file selection -*- lexical-binding: t; -*-

(require 'tab-bar)
(require 'icomplete)
(require 'find-dired)
(require 'cl-lib)

(defvar my-project-search-cache (make-hash-table :test #'equal))
(defvar my-project-search-history nil)
(clrhash my-project-search-cache)

(defun my-project-search-source (root)
  "Return (BASE PROGRAM . ARGS) for listing files below ROOT."
  (cons root (list find-program "-H" (file-local-name root)
                   "-type" "d" "-name" ".git" "-prune" "-o" "-type" "f" "-print0")))

(defun my-project-read-file (root)
  "Choose a file under ROOT while its index is loaded asynchronously."
  (let* ((source (my-project-search-source root))
         (default-directory (car source))
         (cached (gethash root my-project-search-cache))
         (ready (and cached (< (- (float-time) (car cached)) 600)))
         (files (and ready (cadr cached)))
         (completion-styles '(substring))
         (completion-category-defaults nil)
         (completion-category-overrides nil)
         (icomplete-mode t)
         (icomplete-vertical-mode t)
         (icomplete-show-matches-on-no-input nil)
         (icomplete-minibuffer-setup-hook '(icomplete--vertical-minibuffer-setup))
         (active t)
         process output errors minibuffer failure selected)
    (unwind-protect
        (progn
          (unless ready
            (setq output (generate-new-buffer " *project-files*")
                  errors (generate-new-buffer " *project-files-errors*"))
            (setq process
                  (make-process
                   :name "project-files" :buffer output :stderr errors
                   :command (cdr source) :connection-type 'pipe :noquery t :file-handler t
                   :sentinel
                   (lambda (proc _event)
                     (when (and active (memq (process-status proc) '(exit signal)))
                       (setq ready t)
                       (if (zerop (process-exit-status proc))
                           (progn
                             (setq files
                                   (with-current-buffer output
                                     (split-string (buffer-string) "\0" t)))
                             (puthash root (list (float-time) files) my-project-search-cache))
                         (unless failure
                           (setq failure (format "File indexing failed (exit %s): %s"
                                                 (process-exit-status proc)
                                                 (with-current-buffer errors
                                                   (string-trim (buffer-string)))))))
                       (when (and (buffer-live-p minibuffer)
                                  (eq (window-buffer (active-minibuffer-window)) minibuffer))
                         (with-selected-window (active-minibuffer-window)
                           (setq completion-all-sorted-completions nil)
                           (if failure (exit-minibuffer) (icomplete-exhibit)))))))))
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
                         (if ready
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
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p output) (kill-buffer output))
      (when (buffer-live-p errors) (kill-buffer errors)))))

(defun my-project-find-file (&optional refresh)
  "Find a file under the tab's folder or current directory.
With REFRESH, clear the cached file list first."
  (interactive "P")
  (let* ((root (or (alist-get 'my-project-root (tab-bar--current-tab)) default-directory))
         (editor (if (window-parameter (selected-window) 'window-side)
                     (seq-find (lambda (w) (not (window-dedicated-p w))) (window-list))
                   (selected-window)))
         file)
    (when refresh (remhash root my-project-search-cache))
    (setq file (save-window-excursion (my-project-read-file root)))
    (unless (and (stringp file) (not (string-empty-p file)) (file-regular-p file))
      (user-error "Select an existing file, not a directory"))
    (when (window-live-p editor) (select-window editor))
    (find-file file)))

(global-set-key (kbd "C-x p f") #'my-project-find-file)
(provide 'my-project-search)
