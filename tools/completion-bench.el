;;; completion-bench.el --- Throwaway GUI latency experiment -*- lexical-binding: t; -*-
;; Modes: sync = Eglot's own CAPF with Corfu; lazy = go-completion.el (async,
;; 20 ms budget, warmup); lazy-cold = lazy without warmup.
;; Run with completion-bench.py, never load this into a working editor.
(defun bench-log (text)
  (write-region (concat text "\n") nil
                (expand-file-name "progress.log" (getenv "COMPLETION_BENCH_OUT")) t 'silent))
(bench-log "loading")
(setq native-comp-jit-compilation nil)
(setq debug-on-error t
      debugger (lambda (&rest err)
                 (with-temp-file (expand-file-name "failure.txt" (getenv "COMPLETION_BENCH_OUT"))
                   (insert (format "%S\n%s\n" err (backtrace-to-string))))
                 (kill-emacs 1)))
(redisplay t) ; initialize NS font faces before loading packages (see GUI smoke tests)
(bench-log "redisplayed")
(require 'eglot) ; load its char-displayable-p defaults before changing the font
(bench-log "eglot loaded")
(require 'cl-lib)
(require 'json)
(require 'package)
(defconst bench-config (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(defconst bench-out (file-name-as-directory (getenv "COMPLETION_BENCH_OUT")))
(defconst bench-root (file-name-as-directory (getenv "COMPLETION_BENCH_ROOT")))
(defconst bench-mode (getenv "COMPLETION_BENCH_MODE"))
(defconst bench-budget (getenv "COMPLETION_BENCH_BUDGET"))
(defconst bench-warmup (getenv "COMPLETION_BENCH_WARMUP"))
(defvar bench-warmup-ms 0)
(defvar bench-connect-ms 0)
(setq user-emacs-directory bench-out
      package-user-dir (expand-file-name "elpa" bench-config))
(package-initialize)
(bench-log "packages initialized")
;; Use the real theme/setup, but omit unrelated project and chat startup.
(with-temp-buffer
  (insert-file-contents (expand-file-name "init.el" bench-config))
  (goto-char (point-min))
  (let (form)
    (while (not (equal (setq form (read (current-buffer))) '(require 'package)))
      (eval form t))))
(bench-log "theme loaded")
(load (expand-file-name "popup-style.el" bench-config) nil t)
(load (expand-file-name "agent-completion.el" bench-config) nil t)
(bench-log "agent completion loaded")
(defconst bench-lazy (member bench-mode '("lazy" "lazy-cold")))
(defvar bench-warmup-items nil)
(when bench-lazy
  (load (expand-file-name "go-completion.el" bench-config) nil t)
  (if (equal bench-mode "lazy-cold")
      (advice-add 'my-go--warmup :override #'ignore)
    ;; Time the module's own warmup request; its reply is otherwise discarded.
    (advice-add 'jsonrpc-async-request :around
                (lambda (original connection method params &rest args)
                  (if (not (and (eq method :textDocument/completion)
                                (eq (plist-get args :success-fn) #'ignore)))
                      (apply original connection method params args)
                    (let ((start (float-time)))
                      (apply original connection method params
                             (plist-put (copy-sequence args) :success-fn
                                        (lambda (reply)
                                          (setq bench-warmup-ms (* 1000 (- (float-time) start))
                                                bench-warmup-items (length (plist-get reply :items))))))))))))
(require 'project)
(require 'corfu-auto)
(setq eglot-sync-connect t
      eglot-connect-timeout 60
      eglot-events-buffer-config '(:size 0)
      eglot-autoshutdown nil
      corfu-auto nil)
(corfu-popupinfo-mode -1) ; measure the candidate list, not delayed documentation
(when bench-budget
  (setq-default eglot-workspace-configuration `(:gopls (:completionBudget ,bench-budget))))
(add-to-list 'eglot-server-programs
             `(go-ts-mode ,(getenv "COMPLETION_BENCH_GOPLS")
                          ,@(when-let* ((budget (or bench-budget (and bench-lazy my-go-completion-budget))))
                              `(:initializationOptions (:completionBudget ,budget)))))
(add-to-list 'treesit-extra-load-path (expand-file-name "tree-sitter" bench-config))
(add-to-list 'treesit-extra-load-path "/opt/local/lib")
(add-to-list 'auto-mode-alist '("\\.go\\'" . go-ts-mode))
(defun bench-project (dir)
  (when (file-in-directory-p dir bench-root) (cons 'transient bench-root)))
(add-hook 'project-find-functions #'bench-project)

;; Lazy mode installs its own Corfu auto settings; sync gets the same ones.
(defun bench-auto-settings ()
  (setq-local corfu-auto t corfu-auto-prefix 1 corfu-auto-delay 0.05 corfu-auto-trigger "."))

(defvar bench-queue nil)
(defvar bench-results nil)
(defvar bench-row nil)
(defvar bench-start 0)
(defvar bench-cache nil)
(defvar bench-buffer nil)
(defvar bench-beg nil)
(defvar bench-end nil)
(defvar bench-last-heartbeat nil)
(defvar bench-gap 0)
(defvar bench-heartbeat nil)
(defvar bench-requests 0)
(defvar bench-wait nil "(PREDICATE . CONTINUATION) checked by timers.")
(defvar bench-key-plans nil "Planned times of typed keys not yet processed.")
(defvar bench-key-lags nil)
(defvar bench-last-key 0)

(defun bench-ms () (* 1000.0 (- (float-time) bench-start)))
(defun bench-fail (err)
  (with-temp-file (expand-file-name "failure.txt" bench-out)
    (insert (format "%S\nrow=%S\n" err bench-row))
    (when (buffer-live-p bench-buffer)
      (insert (with-current-buffer bench-buffer
                (format "mode=%S capfs=%S corfu=%S candidates=%d\n"
                        major-mode completion-at-point-functions corfu-mode (length corfu--candidates)))))
    (when (get-buffer "*Messages*")
      (insert (with-current-buffer "*Messages*" (buffer-string)))))
  (kill-emacs 1))
(defun bench-record (key value) (setf (alist-get key bench-row) value))

(defvar bench-checking nil)
(defun bench-check ()
  "Run the pending continuation once its condition holds.
Guarded: `redisplay' inside a condition runs timers, which call this again."
  (unless bench-checking
    (let ((bench-checking t))
      (when-let* ((wait bench-wait)
                  ((buffer-live-p bench-buffer))
                  ((with-current-buffer bench-buffer (funcall (car wait)))))
        (setq bench-wait nil)
        (condition-case err (with-current-buffer bench-buffer (funcall (cdr wait)))
          (error (bench-fail err)))))))
(defun bench-await (predicate continuation)
  (setq bench-wait (cons predicate continuation))
  (bench-check))

(defun bench-heartbeat ()
  (let ((now (float-time)))
    (when bench-last-heartbeat
      (setq bench-gap (max bench-gap (* 1000 (- now bench-last-heartbeat)))))
    (setq bench-last-heartbeat now))
  (bench-check))

(defun bench-request (original server method params &rest args)
  (if (not (eq method :textDocument/completion))
      (apply original server method params args)
    (cl-incf bench-requests)
    (let* ((start (float-time))
           (reply (apply original server method params args)))
      (setq bench-cache reply)
      (bench-record 'rpc_ms (* 1000 (- (float-time) start)))
      (bench-record 'reply_ms (bench-ms))
      reply)))
(advice-add 'eglot--request :around #'bench-request)
(when bench-lazy
  (advice-add 'my-go--send :after (lambda (&rest _) (cl-incf bench-requests)))
  (advice-add 'my-go--show :after (lambda (&rest _) (bench-check))))

(defun bench-trigger ()
  "Open completion as Corfu's automatic completion does, without its delay."
  (when completion-in-region-mode (corfu-quit))
  (let ((corfu-auto-prefix 0)
        (last-command-event ?x))
    (corfu-auto--complete-deferred))
  (redisplay t))

(defun bench-visible ()
  "Non-nil if the popup shows candidates; checks rows and styling."
  (when (and completion-in-region-mode corfu--candidates
             (frame-live-p corfu--frame) (frame-visible-p corfu--frame))
    (redisplay t)
    (let ((rows (with-current-buffer (window-buffer (frame-root-window corfu--frame))
                  (count-lines (point-min) (point-max)))))
      (cl-assert (<= rows 10))
      (cl-assert (equal (face-background 'corfu-default nil t) (face-background 'tooltip nil t)))
      (cl-assert (equal (face-background 'corfu-current nil t) (face-background 'region nil t)))
      (bench-record 'visible_rows rows))
    t))

(defun bench-field () (buffer-substring-no-properties bench-beg (point)))

(defun bench-fresh-p (&optional field)
  "The popup shows a server answer for the text now in the buffer."
  (and completion-in-region-mode
       ;; A synchronous answer is fresh by construction once the popup is up.
       (or (not (or bench-lazy field))
           (equal (car corfu--input)
                  (buffer-substring-no-properties (car completion-in-region--data) (point))))
       (or (null field) (equal (car corfu--input) field))
       (if bench-lazy
           (and (my-go--ours-p) my-go--latest (my-go--fresh-p my-go--latest)
                (eql (my-go--reply-beg my-go--latest) my-go--beg))
         t)
       (bench-visible)))

(defun bench-final-empty-p (field)
  "The popup is open for FIELD with a final (not still scanning) empty answer."
  (and completion-in-region-mode (null corfu--candidates)
       (equal (car corfu--input) field)
       (or (not bench-lazy)
           (and my-go--latest (my-go--fresh-p my-go--latest)
                (not (my-go--scan-pending-p my-go--latest))))))

(defun bench-pages ()
  "Page down twenty times; lazy mode builds candidates as it goes."
  (let (times)
    (dotimes (_ 20)
      (let ((start (float-time)))
        (corfu-scroll-up 1)
        (corfu--exhibit)
        (redisplay t)
        (push (* 1000 (- (float-time) start)) times)))
    (setq times (nreverse times))
    (bench-record 'page_ms (car times))
    (bench-record 'page_max_ms (apply #'max times))
    (bench-record 'pages_total_ms (apply #'+ times))
    (bench-record 'reached_index corfu--index)
    (cl-assert (= corfu--index (min 200 (1- corfu--total))))))

(defun bench-completeness ()
  "Untimed: every candidate reachable from the popup, and the reply size."
  (if (not bench-lazy)
      (let ((items (if (vectorp bench-cache) bench-cache (plist-get bench-cache :items))))
        (bench-record 'candidates corfu--total)
        (bench-record 'response_items (length items)))
    (let ((reply my-go--latest))
      (setf (my-go--reply-limit reply) most-positive-fixnum)
      (let ((query (buffer-substring-no-properties my-go--beg (point))))
        (my-go--matches reply query)
        (while (my-go--scan-pending-p reply) (my-go--matches reply query))
        (bench-record 'candidates (length (my-go--reply-matches reply))))
      (bench-record 'response_items (length (my-go--reply-items reply))))))

(defun bench-finish ()
  "Fresh results are on screen: record, measure pages, continue."
  (bench-record 'fresh_ms (bench-ms))
  (unless (alist-get 'first_ms bench-row) (bench-record 'first_ms (alist-get 'fresh_ms bench-row)))
  (bench-record 'max_timer_gap_ms (max bench-gap (* 1000 (- (float-time) bench-last-heartbeat))))
  (bench-record 'requests bench-requests)
  (if bench-budget
      (let* ((items (if (vectorp bench-cache) bench-cache (plist-get bench-cache :items)))
             (name (format "labels-%d.json" (length bench-results))))
        (bench-record 'response_items (length items))
        (bench-record 'budget bench-budget)
        (bench-record 'warmup bench-warmup)
        (bench-record 'warmup_ms bench-warmup-ms)
        (bench-record 'connect_ms bench-connect-ms)
        (bench-record 'labels_file name)
        (with-temp-file (expand-file-name name bench-out)
          (insert (json-encode
                   (vconcat (mapcar (lambda (item) (substring-no-properties (plist-get item :label))) items))))))
    (bench-pages)
    (bench-completeness))
  (push (copy-tree bench-row) bench-results)
  (run-with-timer 0.05 nil #'bench-next))

(defun bench-edit (prefix)
  (when completion-in-region-mode (corfu-quit))
  (goto-char bench-beg)
  (delete-region bench-beg bench-end)
  (insert prefix)
  (setq bench-end (point))
  (setq eglot--last-inserted-char (char-before))
  (redisplay t))

(defun bench-row (prefix)
  (bench-edit prefix)
  (bench-trigger)
  (bench-record 'dispatch_ms (bench-ms))
  (when (bench-visible) (bench-record 'first_ms (bench-ms)))
  (unless (or bench-lazy (bench-fresh-p)) (error "No synchronous popup"))
  (bench-await #'bench-fresh-p #'bench-finish))

(defun bench-key-done ()
  "Command-loop latency of each typed key, after Corfu's own post-command work."
  (when (and bench-key-plans (eq this-command 'self-insert-command))
    (push (* 1000 (- (float-time) (pop bench-key-plans))) bench-key-lags)))
(add-hook 'post-command-hook #'bench-key-done 100)

(defun bench-typing (suffix)
  "With the broad popup open, type SUFFIX as real key events every 30 ms."
  (bench-edit "Bench")
  (bench-trigger)
  (bench-await
   #'bench-fresh-p
   (lambda ()
     (setq bench-start (float-time) bench-gap 0 bench-last-heartbeat (float-time)
           bench-requests 0 bench-key-lags nil bench-key-plans nil)
     (bench-record 'first_ms nil)  ; the timed part starts with the first key
     (cl-loop for char across suffix for i from 0
              for planned = (+ bench-start (* i 0.03))
              do (setq bench-key-plans (append bench-key-plans (list planned))
                       bench-last-key planned)
              (run-at-time (- planned (float-time)) nil
                           (lambda (c) (setq unread-command-events (append unread-command-events (list c))))
                           char))
     (let ((final (concat "Bench" suffix)))
       (bench-await (lambda () (and (null bench-key-plans)
                                    (or (bench-fresh-p final) (bench-final-empty-p final)
                                        ;; Seen with sync Eglot: the last request is lost.
                                        (> (float-time) (+ bench-last-key 5)))))
                    (lambda ()
                      (setq bench-end (point))  ; typed keys extended the field
                      (bench-record 'timed_out (if (or (bench-fresh-p final) (bench-final-empty-p final))
                                                   :json-false t))
                      (bench-record 'key_lags_ms (vconcat (reverse bench-key-lags)))
                      (bench-record 'after_last_key_ms (* 1000 (- (float-time) bench-last-key)))
                      (bench-finish)))))))

(defun bench-next ()
  (bench-log (format "next %S" (car bench-queue)))
  (condition-case err
      (progn
        (when (buffer-live-p bench-buffer) (switch-to-buffer bench-buffer))
        (if (null bench-queue)
            (progn
              (cancel-timer bench-heartbeat)
              (with-temp-file (expand-file-name "results.json" bench-out)
                (insert (json-encode (vconcat (nreverse bench-results)))))
              (when bench-budget
                (with-temp-file (expand-file-name "settings.json" bench-out)
                  (insert (json-encode
                           `((initialization . ,(eglot-initialization-options (with-current-buffer bench-buffer (eglot-current-server))))
                             (workspace . ,(eglot--workspace-configuration-plist (with-current-buffer bench-buffer (eglot-current-server)))))))))
              ;; Results are written; a shutdown race must not discard them, but is kept.
              (condition-case err (eglot-shutdown (eglot-current-server))
                (error (with-temp-file (expand-file-name "shutdown-error.txt" bench-out)
                         (insert (format "%S\n%s\n" err (backtrace-to-string))))))
              (kill-emacs 0))
          (pcase-let ((`(,workload ,file ,prefix ,reset) (pop bench-queue)))
            (when reset
              (when completion-in-region-mode (corfu-quit))
              (when (and bench-buffer (buffer-live-p bench-buffer))
                (with-current-buffer bench-buffer
                  (bench-edit "// BENCH")
                  (set-buffer-modified-p nil)))
              (find-file (expand-file-name file bench-root))
              (setq bench-buffer (current-buffer))
              (unless (eglot-managed-p)
                (let ((start (float-time)))
                  (eglot-ensure)
                  (run-hooks 'post-command-hook)
                  (setq bench-connect-ms (* 1000 (- (float-time) start)))))
              (cl-assert (eglot-current-server))
              (if bench-lazy
                  (cl-assert (memq #'my-go-completion-at-point completion-at-point-functions))
                (bench-auto-settings)
                (corfu-mode 1))
              (setq bench-cache nil eglot--capf-session nil)
              (when bench-lazy (my-go--reset))
              (goto-char (point-min))
              (search-forward "// BENCH")
              (setq bench-end (point) bench-beg (- (point) 8))
              (recenter)
              (redisplay t))
            (when (equal workload "budget-first")
              (cl-assert (equal bench-budget (plist-get (eglot-initialization-options (eglot-current-server)) :completionBudget)))
              (let ((start (float-time)))
                (pcase bench-warmup
                  ("idle"
                   (let ((deadline (+ (float-time) 2)))
                     (while (< (float-time) deadline) (accept-process-output nil 0.01))))
                  ("prefetch"
                   (bench-edit prefix)
                   (eglot--request (eglot-current-server) :textDocument/completion (eglot--CompletionParams))))
                (setq bench-warmup-ms (* 1000 (- (float-time) start)))))
            (when bench-budget (setq bench-cache nil eglot--capf-session nil))
            (setq bench-row `((workload . ,workload) (file . ,file) (prefix . ,prefix))
                  bench-start (float-time) bench-gap 0 bench-last-heartbeat (float-time)
                  bench-requests 0)
            (when (equal workload "cold")
              (bench-record 'connect_ms bench-connect-ms)
              (when bench-lazy
                (cl-assert (equal my-go-completion-budget
                                  (plist-get (eglot-initialization-options (eglot-current-server))
                                             :completionBudget)))))
            (cond ((equal workload "typing") (bench-typing (substring prefix 5)))
                  ((and (equal workload "cold") (equal bench-mode "lazy"))
                   ;; Warmup is reported on its own; the user-visible row starts after it.
                   (let ((start (float-time)))
                     (bench-await (lambda () bench-warmup-items)
                                  (lambda ()
                                    (bench-record 'warmup_ms bench-warmup-ms)
                                    (bench-record 'warmup_items bench-warmup-items)
                                    (bench-record 'warmup_max_gap_ms bench-gap)
                                    (bench-record 'warmup_wall_ms (* 1000 (- (float-time) start)))
                                    (setq bench-start (float-time) bench-gap 0
                                          bench-last-heartbeat (float-time))
                                    (bench-row prefix)))))
                  (t (bench-row prefix))))))
    ((debug error) (bench-fail err))))

(defun bench-start ()
  (bench-log "starting")
  (condition-case err
      (progn
        (set-frame-size nil 130 40)
        (setq bench-queue '(("cold" "catalog/probe.go" "Bench" t)))
        (dotimes (_ (string-to-number (getenv "COMPLETION_BENCH_ROUNDS")))
          (setq bench-queue
                (append bench-queue
                        '(("initial" "catalog/probe.go" "Bench" t)
                          ("update" "catalog/probe.go" "BenchF" nil)
                          ("update" "catalog/probe.go" "BenchFunc1" nil)
                          ("update" "catalog/probe.go" "BenchFunc19" nil)
                          ("update" "catalog/probe.go" "BenchFunc199" nil)
                          ("initial" "catalog/probe.go" "BenchV" t)
                          ("update" "catalog/probe.go" "BenchVar09" nil)
                          ("initial" "catalog/probe.go" "obj." t)
                          ("update" "catalog/probe.go" "obj.Field0" nil)
                          ("initial" "probe.go" "catalog." t)
                          ("update" "probe.go" "catalog.BenchFunc19" nil)
                          ("typing" "catalog/probe.go" "BenchFunc199" t)
                          ("typing" "catalog/probe.go" "BenchFunc19999" t)
                          ("typing" "catalog/probe.go" "BenchZZZ" t)))))
        (when bench-budget
          (setq bench-queue
                '(("budget-first" "catalog/probe.go" "Bench" t)
                  ("budget-followup" "catalog/probe.go" "BenchF" t)
                  ("budget-followup" "catalog/probe.go" "BenchFunc19" t)
                  ("budget-followup" "catalog/probe.go" "BenchV" t)
                  ("budget-followup" "catalog/probe.go" "obj." t)
                  ("budget-followup" "probe.go" "catalog." t)
                  ("budget-repeat" "catalog/probe.go" "Bench" t))))
        (setq bench-heartbeat (run-with-timer 0 0.01 #'bench-heartbeat))
        (bench-next))
    (error (bench-fail err))))
(add-hook 'emacs-startup-hook (lambda () (run-with-timer 0.5 nil #'bench-start)))
