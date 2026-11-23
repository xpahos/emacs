;;; project-search-tests.el --- Floating file and symbol search -*- lexical-binding: t; -*-
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(load (expand-file-name "../project-search.el" (file-name-directory load-file-name)) nil t)
(require 'go-ts-mode)

(defun my-test-search-wait (predicate &optional seconds)
  (let ((deadline (+ (float-time) (or seconds 3))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro my-test-in-search (&rest body)
  `(with-current-buffer (or (get-buffer my-search-buffer-name) (error "Search dialog is closed")) ,@body))

(defun my-test-search-settle ()
  "Wait until the dialog has rendered its current query."
  (my-test-search-wait
   (lambda () (my-test-in-search (and (null my-search-timer) (equal my-search-query (my-search--read-query)))))))

(defun my-test-search-type (text)
  (my-test-in-search (goto-char my-search-input-end) (insert text))
  (my-test-search-settle))

(defun my-test-search-clear ()
  (my-test-in-search
   (let ((inhibit-read-only t)) (delete-region my-search-input my-search-input-end)))
  (my-test-search-settle))

(defun my-test-search-shown (&optional property)
  (my-test-in-search (mapcar (lambda (it) (plist-get it (or property :key))) my-search-shown)))

(defun my-test-search-status ()
  (my-test-in-search (let ((start (text-property-any (point-min) (point-max) 'my-search-status t)))
                       (string-trim (buffer-substring-no-properties
                                     start (next-single-property-change start 'my-search-status nil (save-excursion (goto-char start) (pos-eol))))))))

(defmacro my-test-search-source (command &rest body)
  "Run BODY with file enumeration replaced by the shell COMMAND."
  `(cl-letf (((symbol-function 'my-project-search-source)
              (lambda (dir) (list dir "/bin/sh" "-c" ,command))))
     ,@body))

(defun my-test-search-cleaned-up ()
  (should-not (get-buffer my-search-buffer-name))
  (should-not (seq-some (lambda (p) (and (process-live-p p) (string-prefix-p "project-files" (process-name p))))
                        (process-list)))
  (should-not (seq-some (lambda (b) (string-prefix-p " *project-files-errors*" (buffer-name b))) (buffer-list))))

;;; Files

(ert-deftest my-project-search-keeps-all-path-fragments ()
  (with-temp-buffer
    (setq my-search-kind 'file)
    (let ((item (my-search--file-item "/arc/cloud/compute/go/" "/arc/cloud/compute/go/common/pkg/hw/pci/class.go")))
      (should (equal (plist-get item :match) "common/pkg/hw/pci/class.go"))
      (dolist (query '("cloud/compute/go/common/pkg/hw/pci/class.go" "go/common/pkg/hw/pci/class.go"
                       "common/pkg/hw/pci/class.go" "PCI/Class" "class.go"))
        (setq my-search-query query)
        (should (my-search--match-p item)))
      (setq my-search-query "other.go")
      (should-not (my-search--match-p item)))))

(ert-deftest my-project-search-does-not-detect-or-query-vcs ()
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (&rest _) (error "File search must not detect a VCS"))))
    (let* ((root "/tmp/plain folder/cloud/compute/go/")
           (spec (my-project-search-source root)))
      (should (equal (car spec) root))
      (should (equal (cadr spec) find-program))
      (should (member root (cdr spec))))))

(ert-deftest my-project-search-opens-file-without-an-open-project ()
  (my-test-projects
   (let* ((default-directory (file-name-as-directory test-root))
          (file (expand-file-name "a file.txt" test-root))
          (origin (selected-window)))
     (with-temp-file file (insert "example\n"))
     (make-directory (expand-file-name "directory.txt" test-root))
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-type "a file")
     (should (equal (my-test-search-shown) '("a file.txt")))
     (my-test-in-search (my-search-open-selected))
     (should (eq (selected-window) origin))
     (should (equal buffer-file-name file))
     (my-test-search-cleaned-up))))

(ert-deftest my-project-search-rejects-files-gone-before-enter ()
  (my-test-projects
   (my-project-open test-root)
   (let ((original (current-buffer)) (file (expand-file-name "gone.txt" test-root)))
     (with-temp-file file (insert "x\n"))
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-type "gone")
     (delete-file file)
     (should-error (my-test-in-search (my-search-open-selected)) :type 'user-error)
     (my-search-close)
     (should (eq (current-buffer) original))
     (my-test-search-cleaned-up))))

(ert-deftest my-project-search-close-restores-editor-and-stops-work ()
  (my-test-projects
   (my-project-open test-root)
   (let ((original (current-buffer)) (origin (selected-window)) (windows (window-list)))
     (my-test-search-source "exec sleep 10"
       (my-project-find-file)
       (should (process-live-p (get-process "project-files")))
       (my-test-in-search (my-search-close)))
     (should (eq (selected-window) origin))
     (should (eq (current-buffer) original))
     (should (equal (window-list) windows))
     (my-test-search-cleaned-up))))

(ert-deftest my-project-search-refreshes-files-on-each-open ()
  (my-test-projects
   (my-project-open test-root)
   (let ((old (expand-file-name "old.txt" test-root)) (new (expand-file-name "new.txt" test-root)))
     (with-temp-file old (insert "old\n"))
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-type ".txt")
     (should (equal (my-test-search-shown) '("old.txt")))
     (my-search-close)
     (delete-file old)
     (with-temp-file new (insert "new\n"))
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-type ".txt")
     (should (equal (my-test-search-shown) '("new.txt")))
     (my-search-close))))

(ert-deftest my-project-search-offers-recent-files-before-indexing-finishes ()
  (my-test-projects
   (my-project-open test-root)
   (let ((recent (expand-file-name "recent.txt" test-root)) process)
     (with-temp-file recent (insert "x\n"))
     (find-file-noselect recent)
     (my-test-search-source "printf '%s/first.txt\\000%s/recent.txt\\000' \"$PWD\" \"$PWD\"; exec sleep 10"
       (progn
         (my-project-find-file)
         ;; Open files are offered at once, before enumeration answers.
         (my-test-in-search
          (should (equal (mapcar (lambda (it) (plist-get it :key)) my-search-matches) '("recent.txt")))
          (should my-search-loading))
         (setq process (get-process "project-files"))
         (my-test-search-type "txt")
         (my-test-search-wait (lambda () (member "first.txt" (my-test-search-shown))))
         (should (process-live-p process))
         ;; The recent file listed again by `find' is not duplicated and keeps its rank.
         (should (equal (my-test-search-shown) '("recent.txt" "first.txt")))
         (should (string-match-p "Indexing" (my-test-search-status)))
         ;; A path split across chunks is not offered until complete.
         (funcall (process-filter process) process (concat test-root "/sec"))
         (my-test-search-settle)
         (should-not (member "second.txt" (my-test-search-shown)))
         (funcall (process-filter process) process "ond.txt\0")
         (my-test-search-wait (lambda () (member "second.txt" (my-test-search-shown))))
         (my-search-close)
         (should-not (process-live-p process))
         ;; A late chunk after closing is ignored without error.
         (funcall (process-filter process) process (concat test-root "/late.txt\0"))
         (my-test-search-cleaned-up))))))

(ert-deftest my-project-search-keeps-selection-when-results-arrive ()
  (my-test-projects
   (my-project-open test-root)
   (my-test-search-source "exec sleep 10"
     (let ((buffer (progn (my-project-find-file) (get-buffer my-search-buffer-name))))
       (my-search--add buffer (list (my-search--file-item test-root (concat test-root "/pkg/long-name.go"))
                                    (my-search--file-item test-root (concat test-root "/pkg/longer-name.go"))))
       (my-test-search-type "name")
       (should (equal (my-test-search-shown) '("pkg/long-name.go" "pkg/longer-name.go")))
       (my-test-in-search (my-search-next))
       ;; A shorter match sorts first, yet the selection stays on the chosen file.
       (my-search--add buffer (list (my-search--file-item test-root (concat test-root "/name.go"))
                                    (my-search--file-item test-root (concat test-root "/pkg/long-name.go"))))
       (my-test-search-settle)
       (should (equal (my-test-search-shown) '("name.go" "pkg/long-name.go" "pkg/longer-name.go")))
       (my-test-in-search (should (equal my-search-selected "pkg/longer-name.go")))
       ;; A selection that no longer matches falls back to the first result.
       (my-test-search-clear)
       (my-test-search-type "long-")
       (my-test-in-search (should (equal my-search-selected "pkg/long-name.go")))
       (my-search-close)))))

(ert-deftest my-project-search-reports-empty-and-failed-enumeration ()
  (my-test-projects
   (my-project-open test-root)
   (my-test-search-source "echo 'permission denied' >&2; exit 7"
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-settle)
     (should (string-match-p "File indexing failed (exit 7): permission denied" (my-test-search-status)))
     (my-search-close))
   (my-test-search-source "exit 0"
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-type "anything")
     (should (equal (my-test-search-status) "No matching files"))
     (my-test-in-search (my-search-open-selected))
     (should (get-buffer my-search-buffer-name))
     (my-search-close))
   (my-test-search-cleaned-up)))

(defun my-test-search-files (root &rest names)
  (dolist (name names) (with-temp-file (expand-file-name name root) (insert name "\n"))))

(defun my-test-search-replace (text)
  "Replace the query with TEXT without letting the refresh timer run."
  (my-test-in-search
   (let ((inhibit-read-only t))
     (delete-region my-search-input my-search-input-end)
     (goto-char my-search-input)
     (insert text))
   (should (timerp my-search-timer))))

(ert-deftest my-project-search-enter-uses-the-query-as-typed ()
  (my-test-projects
   (my-project-open test-root)
   (my-test-search-files test-root "alpha.txt" "beta.txt")
   (my-project-find-file)
   (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
   (my-test-search-type "alpha")
   (should (equal (my-test-search-shown) '("alpha.txt")))
   ;; Confirm before the 50 ms refresh: the new query's result opens, not the old one.
   (my-test-search-replace "beta")
   (my-test-in-search (my-search-open-selected))
   (should (equal buffer-file-name (expand-file-name "beta.txt" test-root)))
   (my-test-search-cleaned-up)
   ;; No result for the typed query yet: the dialog stays open.
   (switch-to-buffer "*scratch*")
   (my-project-find-file)
   (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
   (my-test-search-type "alpha")
   (my-test-search-replace "zzz")
   (my-test-in-search (my-search-open-selected))
   (should (get-buffer my-search-buffer-name))
   (should (equal (buffer-name (window-buffer (selected-window))) my-search-buffer-name))
   (my-search-close)))

(ert-deftest my-project-search-closes-after-settled-project-change ()
  (my-test-projects
   (my-project-open test-root)
   (my-test-search-files test-root "alpha.txt")
   (let ((original (current-buffer)))
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-type "alpha")
     (my-test-in-search (should-not my-search-timer))
     ;; Nothing is pending; only the tab's root changes.
     (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) "/elsewhere/")
     (my-test-search-wait (lambda () (not (get-buffer my-search-buffer-name))) 2)
     (my-test-search-cleaned-up)
     (should (eq (current-buffer) original)))))

(ert-deftest my-project-search-refuses-navigation-after-project-change ()
  (my-test-projects
   (my-project-open test-root)
   (my-test-search-files test-root "alpha.txt")
   (let ((original (current-buffer)))
     (my-project-find-file)
     (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
     (my-test-search-type "alpha")
     (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) "/elsewhere/")
     ;; Enter before the watch notices: no navigation into the old project.
     (should-error (my-test-in-search (my-search-open-selected)) :type 'user-error)
     (should (eq (window-buffer (selected-window)) original))
     (should-not (get-file-buffer (expand-file-name "alpha.txt" test-root)))
     (my-test-search-cleaned-up))))

(ert-deftest my-project-search-stale-close-spares-a-new-dialog ()
  (my-test-projects
   (my-project-open test-root)
   (let ((root (alist-get 'my-project-root (tab-bar--current-tab))) old)
     (my-test-search-source "exec sleep 10"
       (setq old (my-project-find-file))
       (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) "/elsewhere/")
       (should-not (my-search--live-p old))   ; schedules closing OLD
       (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) root)
       (let ((new (my-project-find-file)))
         (should-not (buffer-live-p old))
         (accept-process-output nil 0.3)
         (should (buffer-live-p new))
         (should (my-search--live-p new))
         (my-search-close))))))

(ert-deftest my-project-search-prunes-git-metadata-only ()
  (let ((root (file-name-as-directory (make-temp-file "file-search-prune-" t))))
    (unwind-protect
        (progn
          (dolist (name '(".git/objects/object" "nested/.git/config"
                          ".github/workflows/test.yml" ".env" "untracked.txt"
                          "target/generated.txt" "worktree/.git"))
            (let ((file (expand-file-name name root)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file (insert "fixture\n"))))
          (let* ((source (my-project-search-source root))
                 (default-directory (car source)))
            (with-temp-buffer
              (should (zerop (apply #'call-process (cadr source) nil t nil (cddr source))))
              (should (equal (sort (mapcar (lambda (file) (file-relative-name file root))
                                          (split-string (buffer-string) "\0" t)) #'string<)
                             '(".env" ".github/workflows/test.yml" "target/generated.txt"
                               "untracked.txt" "worktree/.git"))))
            ;; Open files are filtered the same way.
            (dolist (name '(".git/objects/object" "untracked.txt"))
              (find-file-noselect (expand-file-name name root)))
            (should (equal (mapcar (lambda (it) (plist-get it :key)) (my-search--recent-files root))
                           '("untracked.txt")))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b))) (kill-buffer b)))
      (delete-directory root t))))

;;; Go symbols

(defvar my-test-requests nil "Fake gopls requests: (ID QUERY SUCCESS ERROR).")
(defvar my-test-notifications nil)

(defmacro my-test-fake-gopls (&rest body)
  `(let ((my-test-requests nil) (my-test-notifications nil) (go-ts-mode-hook nil) (id 0))
     (cl-letf (((symbol-function 'my-search--go-server) (lambda (&rest _) 'fake-gopls))
               ((symbol-function 'jsonrpc-running-p) (lambda (server) (eq server 'fake-gopls)))
               ((symbol-function 'jsonrpc-notify) (lambda (_ method params) (push (cons method params) my-test-notifications)))
               ((symbol-function 'jsonrpc-async-request)
                (lambda (_ _method params &rest args)
                  (push (list (cl-incf id) (plist-get params :query) (plist-get args :success-fn) (plist-get args :error-fn))
                        my-test-requests)
                  (list id))))
       ,@body)))

(defun my-test-go-file (root name text)
  (let ((file (expand-file-name name root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    (with-current-buffer (find-file-noselect file) (go-ts-mode) (current-buffer))))

(defun my-test-symbol (file line name &optional kind)
  `(:name ,name :kind ,(or kind 12)
    :location (:uri ,(eglot-path-to-uri file) :range (:start (:line ,(1- line) :character 5) :end (:line ,(1- line) :character 8)))))

(ert-deftest my-project-symbols-show-open-files-before-gopls-answers ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (my-test-fake-gopls
    (let* ((a (my-test-go-file test-root "a/a.go" "package a\n\nfunc Run() {}\n"))
           (b (my-test-go-file test-root "b/b.go" "package b\n\ntype Server struct{}\n\nfunc (s *Server) Run() {}\n"))
           (other (expand-file-name "c/c.go" test-root)))
      (switch-to-buffer a)
      (my-project-find-symbol)
      (my-test-search-type "Run")
      ;; Both identically named local symbols, distinguished by location, before any reply.
      (should (equal (my-test-search-shown :name) '("Run" "Server.Run")))
      (should (string-match-p "Searching gopls" (my-test-search-status)))
      (pcase-let ((`(,_ ,query ,success ,_) (car my-test-requests)))
        (should (equal query "Run"))
        (funcall success (vector (my-test-symbol (buffer-file-name b) 5 "Server.Run" 6)
                                 (my-test-symbol other 3 "Run")
                                 (my-test-symbol "/outside/project/x.go" 1 "Run"))))
      (my-test-search-settle)
      ;; The server's copy of a local symbol is merged; outside files are dropped.
      (should (equal (my-test-search-shown :name) '("Run" "Server.Run" "Run")))
      (should (equal (my-test-search-shown :rel) '("a/a.go" "b/b.go" "c/c.go")))
      (should (equal (my-test-search-status) "3 results"))
      (my-test-in-search (my-search-next))
      (my-test-in-search (my-search-open-selected))
      (should (eq (current-buffer) b))
      (should (= (line-number-at-pos) 5))
      (should (looking-at-p "Run()"))
      (my-test-search-cleaned-up)))))

(ert-deftest my-project-symbols-ignore-stale-and-closed-replies ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (my-test-fake-gopls
    (let ((file (expand-file-name "x.go" test-root)))
      (switch-to-buffer (my-test-go-file test-root "x.go" "package x\n"))
      (my-project-find-symbol)
      (my-test-search-type "Old")
      (my-test-search-clear)
      (my-test-search-type "New")
      (should (equal (mapcar #'cadr my-test-requests) '("New" "Old")))
      ;; The superseded request is cancelled at gopls.
      (should (member '($/cancelRequest :id 1) my-test-notifications))
      (funcall (nth 2 (cadr my-test-requests)) (vector (my-test-symbol file 1 "Old")))
      (my-test-search-settle)
      (should-not (my-test-search-shown))
      (should (string-match-p "Searching" (my-test-search-status)))
      (funcall (nth 2 (car my-test-requests)) (vector (my-test-symbol file 1 "Newer")))
      (my-test-search-settle)
      (should (equal (my-test-search-shown :name) '("Newer")))
      ;; Typing on keeps matching earlier answers until gopls replies again.
      (my-test-search-type "er")
      (should (equal (my-test-search-shown :name) '("Newer")))
      (let ((pending (car my-test-requests)))
        (my-search-close)
        (should (member '($/cancelRequest :id 3) my-test-notifications))
        (funcall (nth 2 pending) (vector (my-test-symbol file 1 "Late")))
        (funcall (nth 3 pending) '(:message "cancelled")))
      (my-test-search-cleaned-up)))))

(ert-deftest my-project-symbols-report-server-failure-and-absence ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (switch-to-buffer (let ((go-ts-mode-hook nil)) (my-test-go-file test-root "x.go" "package x\n\nfunc Local() {}\n")))
   (my-test-fake-gopls
    (my-project-find-symbol)
    (my-test-search-type "Missing")
    (funcall (nth 3 (car my-test-requests)) '(:message "no views"))
    (my-test-search-settle)
    (should (string-match-p "Go language server: no views" (my-test-search-status)))
    (my-search-close))
   (cl-letf (((symbol-function 'my-search--go-server) #'ignore))
     (my-project-find-symbol)
     (my-test-search-type "Loc")
     (should (string-match-p "Go language server is not connected" (my-test-search-status)))
     (should (equal (my-test-search-shown :name) '("Local")))
     (my-test-search-clear)
     (my-test-search-type "Nothing")
     (should (string-match-p "not connected · 0 results" (my-test-search-status)))
     (my-search-close))
   (my-test-search-cleaned-up)))

(ert-deftest my-project-symbols-convert-server-columns-by-encoding ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (my-test-fake-gopls
    (let ((file (expand-file-name "emoji.go" test-root))
          (origin (my-test-go-file test-root "origin.go" "package p\n")))
      (with-temp-file file (insert "package p\n\nvar X = \"😀Target\"; var Target = 1\n"))
      ;; Columns of the declared Target, after 9 ASCII characters, 😀 and 13 more.
      (pcase-dolist (`(,encoding . ,column) '(("utf-16" . 24) ("utf-32" . 23) ("utf-8" . 26) (nil . 24)))
        (switch-to-buffer origin)
        (cl-letf (((symbol-function 'eglot--capabilities) (lambda (_) (list :positionEncoding encoding))))
          (my-project-find-symbol)
          (my-test-search-type "Target")
          (pcase-let ((`(,_ ,_ ,success ,_) (car my-test-requests)))
            (funcall success (vector `(:name "Target" :kind 13
                                       :location (:uri ,(eglot-path-to-uri file)
                                                  :range (:start (:line 2 :character ,column)
                                                          :end (:line 2 :character ,(+ column 6))))))))
          (my-test-search-settle)
          (my-test-in-search (my-search-open-selected)))
        (should (equal buffer-file-name file))
        (should (looking-at-p "Target = 1"))
        (kill-buffer))))))

(ert-deftest my-project-symbols-local-columns-are-characters ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (cl-letf (((symbol-function 'my-search--go-server) #'ignore))
     (let ((go-ts-mode-hook nil))
       (switch-to-buffer (my-test-go-file test-root "emoji.go" "package p\n\nvar X = \"😀𝄞Target\"; var Target = 1\n")))
     (goto-char (point-min))
     (my-project-find-symbol)
     (my-test-search-type "Target")
     (should (equal (my-test-search-shown :name) '("Target")))
     (my-test-in-search (my-search-open-selected))
     (should (= (line-number-at-pos) 3))
     (should (looking-at-p "Target = 1")))))

(ert-deftest my-project-symbols-references-use-the-query-as-typed ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (my-test-fake-gopls
    (switch-to-buffer (my-test-go-file test-root "x.go" "package x\n\nfunc Alpha() {}\n"))
    (my-project-find-symbol)
    (my-test-search-type "Alpha")
    (should (equal (my-test-search-shown :name) '("Alpha")))
    (my-test-search-replace "Beta")
    ;; Only gopls could answer "Beta": stay open and keep the request asynchronous.
    (should-error (my-test-in-search (my-search-references)) :type 'user-error)
    (should (get-buffer my-search-buffer-name))
    (should (equal (cadr (car my-test-requests)) "Beta"))
    ;; The superseded "Alpha" answer cannot bring its selection back.
    (funcall (nth 2 (cadr my-test-requests))
             (vector (my-test-symbol (expand-file-name "x.go" test-root) 3 "Alpha")))
    (my-test-search-settle)
    (should-not (my-test-search-shown))
    (my-search-close))))

(ert-deftest my-project-search-edits-stay-inside-the-query ()
  (my-test-projects
   (my-project-open test-root)
   (my-test-search-source "exec sleep 10"
     (my-project-find-file)
     (my-test-in-search
      (should (= (point) my-search-input-end my-search-input))
      ;; At the field's edges Delete and Backspace do nothing instead of failing.
      (my-search-delete-forward 1)
      (my-search-delete-backward 1)
      (let ((kill-ring '("ab\ncd")) (interprogram-paste-function nil)) (my-search-yank))
      (should (equal (my-search--read-query) "ab cd"))
      (should (= (point) my-search-input-end))
      (my-search-delete-forward 1)
      (backward-char 2)
      (my-search-delete-backward 1)
      (should (equal (my-search--read-query) "abcd"))
      ;; Home/End and clicks beyond the field come back to the query.
      (goto-char (point-min)) (my-search--keep-point)
      (should (= (point) my-search-input))
      (goto-char (point-max)) (my-search--keep-point)
      (should (= (point) my-search-input-end))
      (goto-char my-search-input) (forward-char 1)
      (let ((kill-ring nil)) (my-search-kill-line))
      (should (equal (my-search--read-query) "a"))
      (my-search-delete-backward 5)
      (should (equal (my-search--read-query) "")))
     (my-test-search-settle)
     (should (equal (my-test-in-search my-search-query) ""))
     (my-search-close))))

(defun my-test-search-old-version ()
  "Leave the state the previous version of project-search.el left behind."
  (face-spec-set 'my-search-dim '((t :foreground "#34372f" :height 0.85)) 'face-defface-spec)
  (face-spec-set 'my-search-field
                 '((t :background "#898880" :foreground "#20211e"
                      :box (:line-width (8 . 6) :color "#898880")))
                 'face-defface-spec)
  (setq my-search-mode-map (let ((map (make-sparse-keymap)))
                             (define-key map (kbd "RET") #'my-search-open-selected)
                             map))
  (setq-default my-search-rows 14))

(ert-deftest my-project-search-reload-replaces-old-faces-and-keys ()
  (my-test-projects
   (my-project-open test-root)
   (my-test-search-old-version)
   ;; The fixture really reproduces the stale state.
   (should (equal (face-attribute 'my-search-dim :height) 0.85))
   (should (face-attribute 'my-search-field :box))
   (should-not (commandp (lookup-key my-search-mode-map [remap yank])))
   (let ((timers (length timer-list)) (size-hooks (length window-size-change-functions))
         (post-hooks (length (default-value 'post-command-hook))))
     (my-test-search-source "exec sleep 10"
       (my-project-find-file)
       (should (process-live-p (get-process "project-files")))
       ;; An ordinary `load-file' over the old version.
       (load my-search--file nil t)
       ;; ...closed the old dialog and stopped its work.
       (my-test-search-cleaned-up)
       (dolist (face '(my-search-dim my-search-field my-search-border my-search-name my-search-selected))
         (should (eq (face-attribute face :height) 'unspecified))
         (should (eq (face-attribute face :weight) 'unspecified))
         (should (eq (face-attribute face :box) 'unspecified)))
       (should (equal (face-attribute 'my-search-dim :foreground) "#363830"))
       (should (eq (lookup-key my-search-mode-map [remap yank]) #'my-search-yank))
       (should (eq (lookup-key my-search-mode-map [remap delete-char]) #'my-search-delete-forward))
       (should (eq (lookup-key my-search-mode-map [remap delete-backward-char]) #'my-search-delete-backward))
       (should (= (default-value 'my-search-rows) 6))
       ;; Repeating the reload, with a dialog open, is safe and leaves nothing behind.
       (my-project-find-file)
       (my-search-reload)
       (my-search-reload)
       (my-test-search-cleaned-up)
       (should (= (length timer-list) timers))
       (should (= (length window-size-change-functions) size-hooks))
       (should (= (length (default-value 'post-command-hook)) post-hooks))
       ;; A reopened dialog uses the new bindings.
       (my-project-find-file)
       (my-test-in-search
        (should (eq (current-local-map) my-search-mode-map))
        (should (eq (key-binding (kbd "C-y")) #'my-search-yank))
        (should (eq (key-binding (kbd "C-d")) #'my-search-delete-forward))
        (should (eq (key-binding (kbd "DEL")) #'my-search-delete-backward)))
       (my-search-close)
       (my-test-search-cleaned-up)))))

;;; Mouse wheel and trackpad

(defun my-test-wheel (type &optional lines count)
  "Send COUNT wheel events of TYPE, each LINES steps, through the dialog's bindings."
  (my-test-in-search
   (dotimes (_ (or count 1))
     (let* ((window (get-buffer-window (current-buffer) t))
            (event (list type (list window (point) '(0 . 0) 0) 1 lines))
            (command (key-binding (vector type))))
       (funcall command event)
       (my-search--keep-point)))))

(defun my-test-wheel-state ()
  (my-test-in-search
   (list :query (my-search--read-query) :point (- (point) my-search-input)
         :start (window-start (get-buffer-window (current-buffer) t))
         :vscroll (window-vscroll (get-buffer-window (current-buffer) t)))))

(defun my-test-selected-index ()
  (my-test-in-search
   (cl-position my-search-selected my-search-shown :key (lambda (it) (plist-get it :key)) :test #'equal)))

(defun my-test-selection-visible-p ()
  (my-test-in-search
   (let ((index (my-test-selected-index)))
     (and (<= my-search-offset index) (< index (+ my-search-offset my-search-rows))
          (text-property-any my-search-rows-start (point-max) 'my-search-key my-search-selected)))))

(ert-deftest my-project-search-wheel-moves-through-results ()
  (my-test-projects
   (my-project-open test-root)
   (dotimes (i 25) (my-test-search-files test-root (format "file%02d.txt" (1+ i))))
   (my-project-find-file)
   (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
   (my-test-search-type "file")
   (should (= (length (my-test-search-shown)) 25))
   ;; The caret sits inside the query; the wheel must leave it and the dialog alone.
   (my-test-in-search (goto-char (+ my-search-input 2)))
   (let ((before (my-test-wheel-state)))
     (my-test-wheel 'wheel-down nil 8)
     (should (= (my-test-selected-index) 8))
     (should (> (my-test-in-search my-search-offset) 0))
     (should (my-test-selection-visible-p))
     (should (equal (my-test-wheel-state) before))
     ;; Reverse, repeated-click variants and line counts.
     (my-test-wheel 'wheel-up nil 3)
     (should (= (my-test-selected-index) 5))
     (my-test-wheel 'double-wheel-down 3)
     (should (= (my-test-selected-index) 8))
     (my-test-wheel 'mouse-4)
     (should (= (my-test-selected-index) 7))
     ;; Rapid events stop at both ends without wrapping or errors.
     (my-test-wheel 'triple-wheel-down 2 100)
     (should (= (my-test-selected-index) 24))
     (should (my-test-selection-visible-p))
     (my-test-wheel 'wheel-down)
     (should (= (my-test-selected-index) 24))
     (my-test-wheel 'wheel-up nil 100)
     (should (= (my-test-selected-index) 0))
     (should (= (my-test-in-search my-search-offset) 0))
     (should (equal (my-test-wheel-state) before))
     ;; Horizontal wheels do nothing.
     (my-test-wheel 'wheel-right nil 5)
     (should (equal (my-test-wheel-state) before))
     ;; Results arriving later keep the wheel's selection and page.
     (my-test-wheel 'wheel-down nil 12)
     (let ((key (my-test-in-search my-search-selected)))
       (my-search--add (get-buffer my-search-buffer-name)
                       (list (my-search--file-item test-root (concat test-root "/a-file.txt"))))
       (my-test-search-settle)
       (should (equal (my-test-in-search my-search-selected) key))
       (should (my-test-selection-visible-p))
       (my-test-in-search (my-search--render))
       (should (equal (my-test-in-search my-search-selected) key))
       (should (equal (my-test-wheel-state) before))
       ;; Enter opens the highlighted file.
       (my-test-in-search (my-search-open-selected))
       (should (equal buffer-file-name (expand-file-name key test-root)))))
   (my-test-search-cleaned-up)))

(ert-deftest my-project-search-wheel-edge-cases ()
  (my-test-projects
   (my-project-open test-root)
   (dotimes (i 25) (my-test-search-files test-root (format "file%02d.txt" (1+ i))))
   (my-project-find-file)
   (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
   ;; No results.
   (my-test-search-type "zzz")
   (my-test-wheel 'wheel-down nil 3)
   (my-test-wheel 'wheel-up nil 3)
   (should-not (my-test-in-search my-search-selected))
   (should (equal (my-test-in-search (my-search--read-query)) "zzz"))
   ;; One result.
   (my-test-search-clear)
   (my-test-search-type "file07")
   (my-test-wheel 'wheel-down nil 3)
   (should (= (my-test-selected-index) 0))
   (my-test-wheel 'wheel-up nil 3)
   (should (= (my-test-selected-index) 0))
   ;; A shorter dialog pages by whole rows.
   (my-test-search-clear)
   (my-test-search-type "file")
   (my-test-in-search (setq my-search-rows 2) (my-search--render))
   (my-test-wheel 'wheel-down nil 5)
   (should (= (my-test-selected-index) 5))
   (should (= (my-test-in-search my-search-offset) 4))
   (should (= 2 (my-test-in-search
                 (let ((count 0) (pos my-search-rows-start))
                   (while (setq pos (text-property-not-all pos (point-max) 'my-search-key nil))
                     (cl-incf count)
                     (setq pos (next-single-property-change pos 'my-search-key nil (point-max))))
                   count))))
   ;; Keyboard navigation still works alongside.
   (my-test-in-search (my-search-previous))
   (should (= (my-test-selected-index) 4))
   ;; Precision scrolling's minor-mode map does not take the wheel away.
   (my-test-in-search
    (let ((pixel-scroll-precision-mode t))
      (should (eq (key-binding [wheel-down]) #'my-search-wheel)))
    (should (eq (key-binding [header-line wheel-down]) #'my-search-wheel))
    (should (eq (key-binding [wheel-left]) #'ignore)))
   (my-search-close)
   ;; Ordinary buffers keep their scrolling.
   (with-temp-buffer
     (should-not (eq (key-binding [wheel-down]) #'my-search-wheel)))))

(ert-deftest my-project-symbols-wheel-moves-through-results ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (cl-letf (((symbol-function 'my-search--go-server) #'ignore))
     (let ((go-ts-mode-hook nil))
       (switch-to-buffer
        (my-test-go-file test-root "many.go"
                         (concat "package p\n\n"
                                 (mapconcat (lambda (i) (format "func Step%02d() {}\n" i))
                                            (number-sequence 1 25) "")))))
     (my-project-find-symbol)
     (my-test-search-type "Step")
     (should (= (length (my-test-search-shown)) 25))
     (my-test-in-search (goto-char (+ my-search-input 1)))
     (let ((before (my-test-wheel-state)))
       (my-test-wheel 'wheel-down nil 10)
       (should (= (my-test-selected-index) 10))
       (should (my-test-selection-visible-p))
       (should (equal (my-test-wheel-state) before)))
     (my-test-in-search (my-search-open-selected))
     (should (= (line-number-at-pos) 13))
     (should (looking-at-p "Step11")))))

;;; Trackpad pixel deltas

(defun my-test-trackpad (dy &optional count)
  "Send COUNT trackpad events moving DY pixels toward later results."
  (my-test-in-search
   (dotimes (_ (or count 1))
     (let* ((window (get-buffer-window (current-buffer) t))
            (type (if (< dy 0) 'wheel-up 'wheel-down))
            (event (list type (list window (point) '(0 . 0) 0) 1 nil (cons 0 (- dy)))))
       (funcall (key-binding (vector type)) event)
       (my-search--keep-point)))))

(defun my-test-trackpad-row ()
  (let ((row (my-test-in-search (my-search--row-pixels))))
    (should (>= row 2))
    row))

(defun my-test-wheel-pixels () (my-test-in-search my-search-wheel-pixels))

(ert-deftest my-project-search-trackpad-accumulates-pixels ()
  (my-test-projects
   (my-project-open test-root)
   (dotimes (i 25) (my-test-search-files test-root (format "file%02d.txt" (1+ i))))
   (my-project-find-file)
   (my-test-search-wait (lambda () (my-test-in-search (not my-search-loading))))
   (my-test-search-type "file")
   (my-test-in-search (goto-char (+ my-search-input 2)))
   (let ((before (my-test-wheel-state)) (row (my-test-trackpad-row)))
     ;; The same distance as one event or many small ones moves equally far.
     (my-test-trackpad (* 3 row))
     (should (= (my-test-selected-index) 3))
     (my-test-trackpad (- (* 3 row)))
     (should (= (my-test-selected-index) 0))
     (my-test-trackpad 1 (* 3 row))
     (should (= (my-test-selected-index) 3))
     (should (= (my-test-wheel-pixels) 0))
     ;; Less than a row waits; the rest completes exactly one step.
     (my-test-trackpad (1- row))
     (should (= (my-test-selected-index) 3))
     (should (= (my-test-wheel-pixels) (1- row)))
     ;; No vertical movement changes nothing.
     (my-test-trackpad 0 5)
     (should (= (my-test-selected-index) 3))
     (should (= (my-test-wheel-pixels) (1- row)))
     (my-test-trackpad 1)
     (should (= (my-test-selected-index) 4))
     (should (= (my-test-wheel-pixels) 0))
     ;; Reversing is not held back by leftover forward movement.
     (my-test-trackpad (1- row))
     (my-test-trackpad (- row))
     (should (= (my-test-selected-index) 3))
     ;; Ends clamp, and reversing from an end responds to one row.
     (my-test-trackpad row 100)
     (should (= (my-test-selected-index) 24))
     (should (= (my-test-wheel-pixels) 0))
     (my-test-trackpad (- row))
     (should (= (my-test-selected-index) 23))
     (my-test-trackpad (- row) 100)
     (should (= (my-test-selected-index) 0))
     (should (= (my-test-wheel-pixels) 0))
     (my-test-trackpad row)
     (should (= (my-test-selected-index) 1))
     ;; Line-based wheels still step by line count, and drop partial trackpad movement.
     (my-test-trackpad (1- row))
     (my-test-wheel 'wheel-down 2)
     (should (= (my-test-selected-index) 3))
     (should (= (my-test-wheel-pixels) 0))
     (should (my-test-selection-visible-p))
     (should (equal (my-test-wheel-state) before))
     ;; A query change clears leftover movement.
     (my-test-trackpad (1- row))
     (should (= (my-test-wheel-pixels) (1- row)))
     (my-test-search-type "0")
     (should (= (my-test-wheel-pixels) 0))
     ;; So does closing; a reopened dialog starts from nothing.
     (my-test-trackpad (1- row))
     (my-search-close)
     (my-project-find-file)
     (should (= (my-test-wheel-pixels) 0))
     (my-search-close))
   (my-test-search-cleaned-up)))

(ert-deftest my-project-symbols-trackpad-accumulates-pixels ()
  (skip-unless (treesit-language-available-p 'go))
  (my-test-projects
   (my-project-open test-root)
   (cl-letf (((symbol-function 'my-search--go-server) #'ignore))
     (let ((go-ts-mode-hook nil))
       (switch-to-buffer
        (my-test-go-file test-root "many.go"
                         (concat "package p\n\n"
                                 (mapconcat (lambda (i) (format "func Step%02d() {}\n" i))
                                            (number-sequence 1 25) "")))))
     (my-project-find-symbol)
     (my-test-search-type "Step")
     (my-test-in-search (goto-char (+ my-search-input 1)))
     (let ((before (my-test-wheel-state)) (row (my-test-trackpad-row)))
       (my-test-trackpad 1 (* 10 row))
       (should (= (my-test-selected-index) 10))
       (my-test-trackpad (1- row))
       (should (= (my-test-selected-index) 10))
       (should (my-test-selection-visible-p))
       (should (equal (my-test-wheel-state) before)))
     (my-test-in-search (my-search-open-selected))
     (should (looking-at-p "Step11")))))
