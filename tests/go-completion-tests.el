;;; go-completion-tests.el --- Asynchronous Go completion, fake server -*- lexical-binding: t; -*-
(require 'ert)
(require 'package)
(setq package-user-dir (expand-file-name "../elpa" (file-name-directory load-file-name)))
(package-initialize)
(load (expand-file-name "../go-completion.el" (file-name-directory load-file-name)) nil t)

(defvar my-go-test-requests nil "Captured requests, newest first.")
(defvar my-go-test-notes nil "Captured notifications.")
(defvar my-go-test-opened 0 "Popups opened through the auto-completion path.")
(defvar my-go-test-server (make-symbol "server"))

(defmacro my-go-test (text &rest body)
  "Run BODY in a buffer holding TEXT, point at the end, with a fake gopls."
  (declare (indent 1))
  `(let ((my-go-test-requests nil) (my-go-test-notes nil) (my-go-test-opened 0) (id 0))
     (cl-letf (((symbol-function 'eglot-current-server) (lambda () my-go-test-server))
               ((symbol-function 'eglot-server-capable) #'always)
               ((symbol-function 'jsonrpc-running-p) #'always)
               ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
               ((symbol-function 'eglot--CompletionParams) (lambda () (list :point (point))))
               ((symbol-function 'jsonrpc-notify)
                (lambda (_server method params) (push (cons method params) my-go-test-notes)))
               ((symbol-function 'jsonrpc-async-request)
                (lambda (_server _method params &rest callbacks)
                  (push (list :id (cl-incf id) :params params :callbacks callbacks) my-go-test-requests)
                  (list id)))
               ((symbol-function 'corfu-auto--complete-deferred)
                (lambda (&rest _) (cl-incf my-go-test-opened))))
       ;; Not `with-temp-buffer': it inhibits `kill-buffer-hook'.
       (with-current-buffer (generate-new-buffer "go-completion-test")
         (switch-to-buffer (current-buffer))
         (insert ,text)
         (setq-local eglot--docver 0)
         (add-hook 'after-change-functions (lambda (&rest _) (cl-incf eglot--docver)) nil t)
         (pcase-dolist (`(,hook . ,fn) my-go--hooks) (add-hook hook fn nil t))
         (unwind-protect (progn ,@body) (my-go--reset) (kill-buffer))))))

(defun my-go-test-ask ()
  "Call the CAPF and its table as Corfu's auto completion does."
  (let ((capf (my-go-completion-at-point)))
    (my-go--table (buffer-substring-no-properties (car capf) (point)) nil t)))

(defun my-go-test-flush ()
  "Run due timers (request debounce, scan steps, popup refresh)."
  (accept-process-output nil 0.05)
  (dotimes (_ 100)
    (when (or (timerp my-go--scan-timer) (timerp my-go--timer))
      (accept-process-output nil 0.01))))

(defun my-go-test-reply (request items)
  "Answer REQUEST with ITEMS as gopls would."
  (funcall (plist-get (plist-get request :callbacks) :success-fn)
           (list :isIncomplete t :items (vconcat items))))

(defun my-go-test-item (label &rest props)
  (append (list :label label :sortText label) props))

(defun my-go-test-big ()
  (cl-loop for i below 20000 collect (my-go-test-item (format "BenchFunc%05d" i))))

(ert-deftest my-go-completion-requests-without-waiting ()
  (my-go-test "Bench"
    (should-not (my-go-test-ask))              ; nothing cached: no blocking request
    (should my-go--open)
    (should-not my-go-test-requests)           ; sent from a timer, not the input path
    (my-go-test-flush)
    (should (= (length my-go-test-requests) 1))
    (my-go-test-reply (car my-go-test-requests) (my-go-test-big))
    (my-go-test-flush)
    (should (= my-go-test-opened 1))
    (should (= (length (my-go-test-ask)) my-go-completion-chunk))))

(ert-deftest my-go-completion-builds-only-requested-candidates ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (my-go-test-big))
    (let ((built 0))
      (advice-add 'my-go--proxy :before (lambda (&rest _) (cl-incf built)) '((name . count)))
      (unwind-protect
          (progn
            (should (equal (car (my-go-test-ask)) "BenchFunc00000"))  ; server order kept
            (should (= built my-go-completion-chunk))
            (should (= (my-go--reply-scanned my-go--latest) my-go-completion-chunk))
            ;; Narrower prefix: rescans lazily, still bounded by the chunk.
            (insert "Func199")
            (setq built 0)
            ;; Sparse matches: each call examines one step, timers continue the scan.
            (my-go-test-ask)
            (should (<= (my-go--reply-scanned my-go--latest) my-go-completion-scan-step))
            (my-go-test-flush)
            (let ((cands (my-go-test-ask)))
              (should (= (length cands) my-go-completion-chunk))
              (should (= built my-go-completion-chunk))
              (should (< (my-go--reply-scanned my-go--latest) 20000))
              (should (equal (car cands) "BenchFunc00199"))))
        (advice-remove 'my-go--proxy 'count)))))

(ert-deftest my-go-completion-navigation-loads-more ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (my-go-test-big))
    (my-go-test-ask)
    (let ((completion-in-region-mode-predicate #'always)
          (completion-extra-properties nil))
      (corfu--setup (- (point) 5) (point) #'my-go--table nil)
      (unwind-protect
          (progn
            (corfu--update)
            (should (= corfu--total my-go-completion-chunk))
            (corfu-next (1- my-go-completion-chunk))
            (should (> corfu--total my-go-completion-chunk))
            (should (equal (nth corfu--index corfu--candidates)
                           (format "BenchFunc%05d" (1- my-go-completion-chunk))))
            (dotimes (_ 300) (corfu-next))
            (should (equal (nth corfu--index corfu--candidates)
                           (format "BenchFunc%05d" (+ 300 my-go-completion-chunk -1))))
            (should (< corfu--total 20000)))
        (corfu-quit)))))

(ert-deftest my-go-completion-rejects-stale-and-out-of-order-replies ()
  (my-go-test "Ben"
    (my-go-test-ask) (my-go-test-flush)
    (let ((old (car my-go-test-requests)))
      (insert "ch")
      (my-go-test-ask) (my-go-test-flush)
      (should (= (length my-go-test-requests) 2))
      (should (equal (car my-go-test-notes)        ; superseded request cancelled
                     `($/cancelRequest :id ,(plist-get old :id))))
      (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "BenchNew")))
      (my-go-test-reply old (list (my-go-test-item "BenchOld")))
      (should (equal (my-go-test-ask) '("BenchNew"))))))

(ert-deftest my-go-completion-uses-cache-provisionally-and-refreshes ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests)
                      (list (my-go-test-item "BenchFunc1") (my-go-test-item "BenchVar1")))
    (insert "V")
    (should (equal (my-go-test-ask) '("BenchVar1")))  ; cached, shown at once
    (should-not (cdr my-go-test-requests))            ; refresh is debounced
    (my-go-test-flush)
    (should (= (length my-go-test-requests) 2))
    (my-go-test-reply (car my-go-test-requests)
                      (list (my-go-test-item "BenchVar1") (my-go-test-item "BenchVar2")))
    (should (equal (my-go-test-ask) '("BenchVar1" "BenchVar2")))
    (should (= (length my-go-test-requests) 2))))     ; fresh: no further request

(ert-deftest my-go-completion-edit-outside-field-discards-reply ()
  (my-go-test "x\nBench"
    (my-go-test-ask) (my-go-test-flush)
    (save-excursion (goto-char (point-min)) (insert "y"))
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "BenchVar1")))
    (should-not my-go--latest)
    (should (= my-go-test-opened 0))))

(ert-deftest my-go-completion-dismissal-cancels-pending-popup ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (let ((this-command 'keyboard-quit)) (my-go--post-command))
    (should (assq '$/cancelRequest my-go-test-notes))
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "BenchVar1")))
    (my-go-test-flush)
    (should (= my-go-test-opened 0))
    (should-not my-go--latest)))

(ert-deftest my-go-completion-typing-keeps-pending-popup ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (let ((this-command 'self-insert-command)) (my-go--post-command))
    (should my-go--open)))

(ert-deftest my-go-completion-reply-in-hidden-buffer-does-not-open ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (let ((request (car my-go-test-requests)) (go (current-buffer)))
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (my-go-test-reply request (list (my-go-test-item "BenchVar1")))
        (my-go-test-flush)
        (should (= my-go-test-opened 0)))
      (switch-to-buffer go)
      (should (equal (my-go-test-ask) '("BenchVar1"))))))  ; kept as cache

(ert-deftest my-go-completion-killed-buffer-cancels-request ()
  (let (request)
    (my-go-test "Bench"
      (my-go-test-ask) (my-go-test-flush)
      (setq request (car my-go-test-requests))
      (kill-buffer (current-buffer))
      (should (assq '$/cancelRequest my-go-test-notes))
      (my-go-test-reply request (list (my-go-test-item "BenchVar1"))))))

(defun my-go-test-range (line from to)
  `(:start (:line ,line :character ,from) :end (:line ,line :character ,to)))

(ert-deftest my-go-completion-applies-edits-to-request-snapshot ()
  ;; Requested at "fmt.Pr"; the user typed "in" before accepting.
  (my-go-test "package p\n\nfunc f() {\n\tfmt.Pr"
    (my-go-test-ask) (my-go-test-flush)
    (let ((item (my-go-test-item
                 "Println"
                 :textEdit `(:newText "Println" :insert ,(my-go-test-range 3 5 7)
                                      :replace ,(my-go-test-range 3 5 7))
                 :additionalTextEdits `[(:newText "\nimport \"fmt\"\n" :range ,(my-go-test-range 1 0 0))])))
      (my-go-test-reply (car my-go-test-requests) (list item))
      (insert "in")
      (let ((proxy (car (my-go-test-ask))))
        (should (equal proxy "Println"))
        ;; What Corfu does on Enter: replace the field, then call :exit-function.
        (completion--replace (- (point) 4) (point) proxy)
        (my-go--exit proxy 'finished))
      (should (equal (buffer-string)
                     "package p\n\nimport \"fmt\"\n\nfunc f() {\n\tfmt.Println"))
      (should (looking-back "Println" nil))
      (should-not my-go--latest))))

(ert-deftest my-go-completion-never-applies-obsolete-edits ()
  (my-go-test "package p\n\nfunc f() {\n\tfmt.Pr"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests)
                      (list (my-go-test-item
                             "Println"
                             :textEdit `(:newText "Println" :range ,(my-go-test-range 3 5 7))
                             :additionalTextEdits `[(:newText "import \"fmt\"\n" :range ,(my-go-test-range 1 0 0))])))
    (let ((proxy (car (my-go-test-ask))))
      (save-excursion (goto-char (point-min)) (insert "// moved\n"))
      (completion--replace (- (point) 2) (point) proxy)
      (let ((inhibit-message t)) (my-go--exit proxy 'finished))
      (should-not (string-search "import" (buffer-string)))
      (should (string-suffix-p "fmt.Println" (buffer-string))))))

(ert-deftest my-go-completion-budget-only-for-gopls ()
  (let ((contact (cdr (cl-find-if (lambda (entry)
                                    (memq 'go-ts-mode (ensure-list (car entry))))
                                  eglot-server-programs))))
    (should (equal (car contact) "gopls"))
    (should (equal (plist-get (cdr contact) :initializationOptions)
                   '(:completionBudget "20ms"))))
  (should-not (default-value 'eglot-workspace-configuration))
  (should (eq (car (cl-find-if (lambda (entry) (memq 'c-mode (ensure-list (car entry))))
                               eglot-server-programs))
              (car (cl-find-if (lambda (entry) (memq 'c-mode (ensure-list (car entry))))
                               (default-value 'eglot-server-programs))))))

;;; Review regressions

(defun my-go-test-bench-edit (label)
  (my-go-test-item label :textEdit `(:newText ,label :range ,(my-go-test-range 0 0 5))))

(ert-deftest my-go-completion-multiline-paste-after-field-survives ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-bench-edit "BenchVar")))
    (let ((shown (car (my-go-test-ask))))      ; on screen before the paste
      (insert "\nKEEP THIS LINE\n")
      (goto-char 6)
      (should-not (my-go-test-ask))           ; obsolete cache is no longer offered
      (completion--replace 1 6 shown)
      (let ((inhibit-message t)) (my-go--exit shown 'finished))
      (should (equal (buffer-string) "BenchVar\nKEEP THIS LINE\n")))))

(ert-deftest my-go-completion-deletion-crossing-field-invalidates ()
  (my-go-test "Bench\nKEEP\n"
    (goto-char 6)
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "BenchVar")))
    (delete-region 4 12)
    (should-not (my-go--reply-valid my-go--latest))))

(ert-deftest my-go-completion-identifier-typing-keeps-reply ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "BenchVar")))
    (insert "Va")
    (delete-char -1)
    (should (my-go--reply-valid my-go--latest))
    (insert "(")
    (should-not (my-go--reply-valid my-go--latest))))

(ert-deftest my-go-completion-refresh-race-keeps-displayed-edits ()
  (my-go-test "package p\n\nfunc f() {\n\tfmt.Pr"
    (my-go-test-ask) (my-go-test-flush)
    (let ((item (my-go-test-item "Println"
                 :textEdit `(:newText "Println" :range ,(my-go-test-range 3 5 7))
                 :additionalTextEdits `[(:newText "\nimport \"fmt\"\n" :range ,(my-go-test-range 1 0 0))])))
      (my-go-test-reply (car my-go-test-requests) (list item))
      (let ((visible (car (my-go-test-ask))))
        (insert "in")
        (my-go-test-ask) (my-go-test-flush)
        (my-go-test-reply (car my-go-test-requests) (list item))
        ;; Enter before the redraw timer: the displayed (older) candidate is accepted.
        (completion--replace (- (point) 4) (point) visible)
        (my-go--exit visible 'finished)
        (should (equal (buffer-string)
                       "package p\n\nimport \"fmt\"\n\nfunc f() {\n\tfmt.Println"))))))

(ert-deftest my-go-completion-cancelled-reply-keeps-newer-popup ()
  (my-go-test "Ben"
    (my-go-test-ask) (my-go-test-flush)
    (let ((old (car my-go-test-requests)))
      (insert "ch")
      (my-go-test-ask) (my-go-test-flush)
      (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "BenchNew")))
      (my-go-test-reply old (list (my-go-test-item "BenchOld")))
      (my-go-test-flush)
      (should (= my-go-test-opened 1)))))

(ert-deftest my-go-completion-failed-current-request-clears-pending-popup ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (funcall (plist-get (plist-get (car my-go-test-requests) :callbacks) :error-fn) nil)
    (should-not my-go--open)))

(ert-deftest my-go-completion-unmatched-query-scans-in-steps ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (my-go-test-big))
    (my-go-test-ask)
    (insert "ZZZ")
    (let ((start (float-time)))
      (should-not (my-go-test-ask))
      (should (< (- (float-time) start) 0.03)))
    (should (= (my-go--reply-scanned my-go--latest) my-go-completion-scan-step))
    (should my-go--open)                      ; unfinished: not a final "no match"
    (my-go-test-flush)
    (should (= (my-go--reply-scanned my-go--latest) 20000))
    (should-not (my-go-test-ask))
    (should (= my-go-test-opened 0))))

(ert-deftest my-go-completion-match-near-end-is-found-incrementally ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests)
                      (append (my-go-test-big) (list (my-go-test-item "BenchLast"))))
    (insert "L")
    (should-not (my-go-test-ask))
    (my-go-test-flush)                        ; timer steps finish the scan, then open
    (should (= my-go-test-opened 1))
    (should (equal (my-go-test-ask) '("BenchLast")))))

(ert-deftest my-go-completion-prefix-change-restarts-scan ()
  (my-go-test "Bench"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests)
                      (append (my-go-test-big) (list (my-go-test-item "BenchLast"))))
    (insert "ZZZ")
    (my-go-test-ask)
    (delete-char -3)
    (insert "L")
    (my-go-test-ask)
    (should (equal (my-go--reply-query my-go--latest) "BenchL"))
    (my-go-test-flush)
    (should (equal (my-go-test-ask) '("BenchLast")))))

;;; Cache miss: a stale reply without matches must not block the fresh popup

(ert-deftest my-go-completion-fresh-reply-opens-after-cache-miss ()
  (my-go-test "Old"
    (my-go-test-ask) (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "OldName")))
    (my-go-test-flush)
    (should (= my-go-test-opened 1))
    (let ((this-command 'keyboard-quit)) (my-go--post-command))  ; dismissed
    (my-go--cancel)
    (delete-region (point-min) (point-max))
    (insert "New")                       ; same field start: cached reply, no matches
    (should-not (my-go-test-ask))
    (should my-go--open)
    (my-go-test-flush)
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "NewName")))
    (my-go-test-flush)
    (should (= my-go-test-opened 2))     ; no further keystroke needed
    (should (equal (my-go-test-ask) '("NewName")))))

(defun my-go-test-stale-empty-scan ()
  "Cache 20,000 items, then type a prefix none match; flush the scan and request."
  (my-go-test-ask) (my-go-test-flush)
  (my-go-test-reply (car my-go-test-requests) (my-go-test-big))
  (my-go-test-flush)
  (setq my-go-test-opened 0)
  (insert "ZZZ")
  (should-not (my-go-test-ask))
  (my-go-test-flush)                     ; refresh sent; cached scan finishes empty
  ;; Checked directly: another table call would set `my-go--open' again.
  (should my-go--pending)
  (should-not (my-go--scan-pending-p my-go--latest))
  (should my-go--open))

(ert-deftest my-go-completion-empty-cached-scan-keeps-pending-popup ()
  (my-go-test "Bench"
    (my-go-test-stale-empty-scan)
    ;; No CAPF/table call or keystroke from here: the reply alone opens the popup.
    (my-go-test-reply (car my-go-test-requests) (list (my-go-test-item "BenchZZZTop")))
    (my-go-test-flush)
    (should (= my-go-test-opened 1))))

(ert-deftest my-go-completion-dismissal-beats-fresh-reply-after-cache-miss ()
  (my-go-test "Bench"
    (my-go-test-stale-empty-scan)
    (let ((request (car my-go-test-requests)))
      (let ((this-command 'keyboard-quit)) (my-go--post-command))
      (should-not my-go--open)
      (my-go-test-reply request (list (my-go-test-item "BenchZZZTop")))
      (my-go-test-flush)
      (should (= my-go-test-opened 0)))))
