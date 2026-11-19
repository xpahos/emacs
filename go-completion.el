;;; go-completion.el --- Responsive gopls completion in Go buffers -*- lexical-binding: t; -*-

;; Eglot's CAPF waits for gopls, then converts and sorts every item before the
;; popup appears.  Here the request is asynchronous, the reply vector is kept
;; as gopls sent it (already ranked by sortText), and only the rows Corfu needs
;; are turned into candidates.  Insertion restores the request's snapshot of
;; the completion field first, so server edits always apply to the text they
;; were computed for.  Popup style and keys come from agent-completion.el.

(require 'cl-lib)
(require 'eglot)
(require 'corfu)
(require 'corfu-auto)
(require 'treesit)

(defconst my-go-completion-budget "20ms")
(defconst my-go-completion-chunk 50 "Candidates built per on-demand step.")
(defconst my-go-completion-scan-step 2000
  "Items examined per scanning step; a sparse query continues from a timer.")
(defconst my-go-completion-refresh-delay 0.03
  "Typing pause before replacing a request gopls is still working on.")

;; Same modes as Eglot's default gopls entry, so go.mod buffers share the server.
;; Workspace configuration (e.g. .dir-locals) still overrides these options.
(add-to-list 'eglot-server-programs
             `((go-mode go-dot-mod-mode go-dot-work-mode go-ts-mode go-mod-ts-mode)
               . ("gopls" :initializationOptions
                  (:completionBudget ,my-go-completion-budget))))

(cl-defstruct (my-go--reply (:constructor my-go--reply-create) (:copier nil))
  "One completion request and, once answered, its items."
  server id version beg end text items valid
  (limit my-go-completion-chunk) query matches (scanned 0))

(defvar-local my-go--latest nil "Newest answered reply.")
(defvar-local my-go--previous nil "Reply the popup may still show until redrawn.")
(defvar-local my-go--scan-timer nil)
(defvar my-go--inserting nil "Non-nil while Corfu inserts one of our candidates.")
(defvar-local my-go--pending nil "Request in flight.")
(defvar-local my-go--timer nil)
(defvar-local my-go--open nil "Non-nil: open the popup when the reply arrives.")
(defvar-local my-go--beg nil "Start of the field from the last CAPF call.")
(defvar-local my-go--warmed nil)

(defun my-go--field-end (beg)
  (save-excursion (goto-char beg) (skip-syntax-forward "w_") (point)))

(defun my-go--forget (reply)
  "Release REPLY's marker and mark it unusable."
  (when reply
    (setf (my-go--reply-valid reply) nil)
    (set-marker (my-go--reply-end reply) nil)))

(defun my-go--cancel-pending ()
  "Ask gopls to stop the request in flight and ignore its answer."
  (when-let* ((reply my-go--pending))
    (when (jsonrpc-running-p (my-go--reply-server reply))
      (jsonrpc-notify (my-go--reply-server reply) '$/cancelRequest
                      `(:id ,(my-go--reply-id reply))))
    (my-go--forget reply)
    (setq my-go--pending nil)))

(defun my-go--cancel ()
  "Drop the scheduled and in-flight requests and any pending popup."
  (when (timerp my-go--timer) (cancel-timer my-go--timer))
  (when (timerp my-go--scan-timer) (cancel-timer my-go--scan-timer))
  (my-go--cancel-pending)
  (setq my-go--timer nil my-go--scan-timer nil my-go--open nil))

(defun my-go--reset ()
  "Forget all completion state of this buffer."
  (my-go--cancel)
  (my-go--forget my-go--latest)
  (my-go--forget my-go--previous)
  (setq my-go--latest nil my-go--previous nil))

(defun my-go--invalidate (pred)
  "Forget tracked replies satisfying PRED; the popup recomputes without them."
  (unless my-go--inserting
    (dolist (reply (list my-go--latest my-go--pending my-go--previous))
      (when (and reply (my-go--reply-valid reply) (funcall pred reply))
        (my-go--forget reply)
        (when (my-go--ours-p) (setq corfu--input nil))))))

(defun my-go--before-change (b e)
  "A change reaching outside a reply's original field makes its edits obsolete."
  (my-go--invalidate (lambda (reply) (or (< b (my-go--reply-beg reply))
                                         (> e (my-go--reply-end reply))))))

(defun my-go--after-change (b e _len)
  "Inserted text must stay in the identifier, or restoring the field deletes it."
  (when (and (> e b)
             (save-excursion (goto-char b) (skip-syntax-forward "w_" e) (< (point) e)))
    (my-go--invalidate #'always)))

(defun my-go--insert-advice (original &rest args)
  "Corfu's own replacement may insert labels such as \"Thing{}\"."
  (let ((my-go--inserting (my-go--ours-p))) (apply original args)))
(advice-add 'corfu--insert :around #'my-go--insert-advice)

(defun my-go--usable (reply beg)
  (and reply (my-go--reply-items reply) (my-go--reply-valid reply)
       (eql beg (my-go--reply-beg reply))
       (eq (my-go--reply-server reply) (eglot-current-server))))

(defun my-go--fresh-p (reply)
  (eql (my-go--reply-version reply) eglot--docver))

(defun my-go--proxy (item reply)
  "Candidate string for ITEM, as Eglot builds it."
  (let* ((label (plist-get item :label))
         (text (plist-get item :insertText))
         (proxy (if (or (eql (plist-get item :insertTextFormat) 2) (plist-get item :textEdit)
                        (null text) (string-empty-p text))
                    (string-trim-left label)
                  text)))
    (setq proxy (copy-sequence proxy))
    (unless (string-empty-p proxy)
      (add-text-properties 0 1 `(eglot--lsp-item ,item my-go--reply ,reply) proxy))
    proxy))

(defun my-go--flex-regexp (query)
  (mapconcat (lambda (c) (regexp-quote (string c))) query ".*"))

(defun my-go--scan-pending-p (reply)
  (and (< (length (my-go--reply-matches reply)) (my-go--reply-limit reply))
       (< (my-go--reply-scanned reply) (length (my-go--reply-items reply)))))

(defun my-go--continue-scan (buffer)
  "Examine the next step of the newest reply, then redraw; yields to input."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq my-go--scan-timer nil)
      (when-let* ((reply (and (my-go--usable my-go--latest my-go--beg) my-go--latest))
                  ((my-go--reply-query reply))
                  ((my-go--scan-pending-p reply)))
        (if (input-pending-p)
            (setq my-go--scan-timer (run-at-time 0.01 nil #'my-go--continue-scan buffer))
          ;; Finished without matches: only a fresh reply means none are coming.
          (unless (or (my-go--matches reply (my-go--reply-query reply))
                      (my-go--scan-pending-p reply)
                      (not (my-go--fresh-p reply)))
            (setq my-go--open nil))
          (my-go--show buffer))))))

(defun my-go--matches (reply query)
  "First `limit' candidates of REPLY matching QUERY.
Examines at most `my-go-completion-scan-step' items per call; the rest
of a sparse scan continues from a timer and redraws the popup."
  (unless (equal query (my-go--reply-query reply))
    (when (my-go--reply-query reply) (setf (my-go--reply-limit reply) my-go-completion-chunk))
    (setf (my-go--reply-query reply) query
          (my-go--reply-matches reply) nil
          (my-go--reply-scanned reply) 0))
  (let* ((items (my-go--reply-items reply))
         (want (- (my-go--reply-limit reply) (length (my-go--reply-matches reply))))
         (i (my-go--reply-scanned reply))
         (regexp (my-go--flex-regexp query))
         (case-fold-search t)
         stop found)
    (setq stop (min (length items) (+ i my-go-completion-scan-step)))
    (while (and (> want 0) (< i stop))
      (let* ((item (aref items i))
             (text (or (plist-get item :filterText) (plist-get item :label))))
        (when (string-match-p regexp text)
          (let ((proxy (my-go--proxy item reply)))
            (eglot--dumb-flex query proxy t)
            (push proxy found))
          (cl-decf want)))
      (cl-incf i))
    (setf (my-go--reply-scanned reply) i
          (my-go--reply-matches reply) (nconc (my-go--reply-matches reply) (nreverse found)))
    (when (and (my-go--scan-pending-p reply) (not (timerp my-go--scan-timer)))
      (setq my-go--scan-timer (run-at-time 0 nil #'my-go--continue-scan (current-buffer))))
    (my-go--reply-matches reply)))

(defun my-go--schedule ()
  "Ask gopls about the current field unless that request is already out."
  (let ((beg my-go--beg))
    (unless (and my-go--pending (my-go--fresh-p my-go--pending)
                 (eql beg (my-go--reply-beg my-go--pending)))
      (when (timerp my-go--timer) (cancel-timer my-go--timer))
      (setq my-go--timer
            ;; Debounce only while gopls is still busy with an older field.
            (run-at-time (if my-go--pending my-go-completion-refresh-delay 0)
                         nil #'my-go--send (current-buffer) beg)))))

(defun my-go--send (buffer beg)
  "Request completions for the field at BEG in BUFFER without waiting."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq my-go--timer nil)
      (when-let* ((server (eglot-current-server))
                  ((eql beg (car (my-go--bounds)))))
        (eglot--signal-textDocument/didChange)
        (my-go--cancel-pending)
        (let* ((end (copy-marker (my-go--field-end beg) t))
               (reply (my-go--reply-create
                       :server server :version eglot--docver :beg beg :end end
                       :text (buffer-substring-no-properties beg end) :valid t)))
          (setf (my-go--reply-id reply)
                (car (jsonrpc-async-request
                      server :textDocument/completion (eglot--CompletionParams)
                      :success-fn (lambda (response) (my-go--arrive buffer reply response))
                      :error-fn (lambda (_) (my-go--arrive buffer reply nil))
                      :timeout-fn (lambda () (my-go--arrive buffer reply nil)))))
          (setq my-go--pending reply))))))

(defun my-go--arrive (buffer reply response)
  "Keep RESPONSE if it is the newest valid answer, then refresh the popup."
  (if (not (buffer-live-p buffer))
      (my-go--forget reply)
    (with-current-buffer buffer
      (if (not (and response (my-go--reply-valid reply)
                    (or (null my-go--latest)
                        (> (my-go--reply-id reply) (my-go--reply-id my-go--latest)))))
          (progn
            ;; Only the current request failing means no popup is coming.
            (when (eq reply my-go--pending) (setq my-go--pending nil my-go--open nil))
            (my-go--forget reply))
        (when (eq reply my-go--pending) (setq my-go--pending nil))
        (setf (my-go--reply-items reply)
              (if (vectorp response) response (or (plist-get response :items) [])))
        (when (and (my-go--ours-p) (> corfu--index 0))
          ;; Keep the selected row loaded so Corfu can keep it selected.
          (setf (my-go--reply-limit reply) (+ corfu--index my-go-completion-chunk)))
        ;; The popup may show the old reply until redrawn; keep its edits usable.
        (unless (eq my-go--previous my-go--latest) (my-go--forget my-go--previous))
        (setq my-go--previous my-go--latest my-go--latest reply)
        ;; Out of the process filter; the next command redraws if input is waiting.
        (run-at-time 0 nil #'my-go--show buffer)))))

(defun my-go--ours-p ()
  (and completion-in-region-mode (eq (nth 2 completion-in-region--data) #'my-go--table)))

(defun my-go--show (buffer)
  "Redraw or open BUFFER's popup with the newest reply."
  (when (and (buffer-live-p buffer) (eq buffer (window-buffer (selected-window)))
             (corfu--popup-support-p))
    (with-current-buffer buffer
      (cond ((my-go--ours-p)
             (setq corfu--input nil)  ; else the next command redraws it
             (unless (input-pending-p)
               (corfu--exhibit)
               (my-go--forget my-go--previous)
               (setq my-go--previous nil)))
            ((and my-go--open (not (input-pending-p))
                  (my-go--usable my-go--latest (car (my-go--bounds)))
                  ;; Not filtered yet, or a scan step found something.
                  (or (null (my-go--reply-query my-go--latest))
                      (my-go--reply-matches my-go--latest)))
             (setq my-go--open nil)
             (let ((corfu-auto-prefix 0)) (corfu-auto--complete-deferred)))))))

(defun my-go--table (string _pred action)
  "Completion table over the newest usable reply for the current field."
  (pcase action
    ('metadata '(metadata (category . eglot-capf) (display-sort-function . identity)
                          (cycle-sort-function . identity)))
    (`(boundaries . ,_) nil)
    (_ (let ((reply (and (my-go--usable my-go--latest my-go--beg) my-go--latest)))
         (unless (and reply (my-go--fresh-p reply)) (my-go--schedule))
         (let ((cands (and reply (my-go--matches reply string))))
           ;; Nothing to show yet, but gopls or an unfinished scan may still find
           ;; some: open the popup when they do.
           (when (and (null cands) (not completion-in-region-mode)
                      (or (not (and reply (my-go--fresh-p reply)))
                          (my-go--scan-pending-p reply)))
             (setq my-go--open t))
           (pcase action
             ('t cands)
             ('nil (try-completion string cands))
             ('lambda (test-completion string cands))))))))

(defun my-go--bounds ()
  (or (bounds-of-thing-at-point 'symbol) (cons (point) (point))))

(defun my-go--annotate (proxy)
  (when-let* ((item (get-text-property 0 'eglot--lsp-item proxy))
              (text (or (and (not (equal (plist-get item :detail) "")) (plist-get item :detail))
                        (alist-get (plist-get item :kind) eglot--kind-names))))
    (concat " " (propertize text 'face 'completions-annotations))))

(defun my-go--doc-buffer (proxy)
  (when-let* ((doc (plist-get (get-text-property 0 'eglot--lsp-item proxy) :documentation)))
    (with-current-buffer (get-buffer-create " *eglot doc*")
      (erase-buffer)
      (insert (eglot--format-markup doc))
      (current-buffer))))

(defun my-go--exit (proxy status)
  "Apply PROXY's edits to the snapshot they were computed for."
  (when (memq status '(finished exact))
    (let ((item (get-text-property 0 'eglot--lsp-item proxy))
          (reply (get-text-property 0 'my-go--reply proxy)))
      (if (not (and item reply (my-go--reply-valid reply)))
          (message "Go completion: buffer changed, inserted %s without its edits" proxy)
        (eglot--dbind ((CompletionItem) insertTextFormat insertText textEdit
                       additionalTextEdits label)
            item
          (let ((snippet-fn (and (eql insertTextFormat 2) (eglot--snippet-expansion-fn))))
            (cond (textEdit
                   (let ((beg (my-go--reply-beg reply)))
                     (delete-region beg (my-go--reply-end reply))
                     (goto-char beg)
                     (insert (my-go--reply-text reply)))
                   (pcase-let ((`(,beg . ,end)
                                (eglot-range-region (or (plist-get textEdit :replace)
                                                        (plist-get textEdit :range)))))
                     (delete-region beg end)
                     (goto-char beg)
                     (funcall (or snippet-fn #'insert) (plist-get textEdit :newText))))
                  (snippet-fn
                   (delete-region (- (point) (length proxy)) (point))
                   (funcall snippet-fn (or insertText label))))
            (when (cl-plusp (length additionalTextEdits))
              (eglot--apply-text-edits additionalTextEdits)))))
        (eglot--signal-textDocument/didChange)))
  (my-go--reset))

(defun my-go-completion-at-point ()
  "Asynchronous, lazily filtered replacement for `eglot-completion-at-point'."
  (when (eglot-server-capable :completionProvider)
    (let ((bounds (my-go--bounds)))
      (setq my-go--beg (car bounds))
      (list (car bounds) (cdr bounds) #'my-go--table
            :annotation-function #'my-go--annotate
            :company-doc-buffer #'my-go--doc-buffer
            :company-prefix-length (eq (char-before (car bounds)) ?.)
            :exit-function #'my-go--exit))))

(defun my-go--load-more (index)
  "Before Corfu moves to INDEX, build the next chunk if INDEX reaches the end."
  (when-let* (((my-go--ours-p))
              ((>= index (1- corfu--total)))
              (reply (and (my-go--usable my-go--latest my-go--beg) my-go--latest))
              ((< (my-go--reply-scanned reply) (length (my-go--reply-items reply)))))
    (setf (my-go--reply-limit reply) (+ index 1 my-go-completion-chunk))
    (setq corfu--input nil)
    (corfu--update)))
(advice-add 'corfu--goto :before #'my-go--load-more)

(defun my-go--popup-closed ()
  "A dismissed or finished popup must not be reopened by a late reply."
  (unless completion-in-region-mode (my-go--cancel)))

(defun my-go--post-command ()
  "Any command other than typing cancels a popup that has not opened yet."
  (when (and my-go--open (not completion-in-region-mode)
             (not (corfu--match-symbol-p (cons 'completion-at-point corfu-auto-commands)
                                         this-command)))
    (my-go--cancel)))

(defun my-go--warmup-position ()
  "End of the first identifier inside a function body, if any."
  (when-let* (((treesit-parser-list))
              (node (treesit-search-subtree
                     (treesit-buffer-root-node)
                     (lambda (n)
                       (and (equal (treesit-node-type n) "identifier")
                            (treesit-parent-until
                             n (lambda (p) (equal (treesit-node-type p) "block"))))))))
    (treesit-node-end node)))

(defun my-go--warmup ()
  "Type-check the visible file's package before the first completion.
The prefix is a whole identifier, so the discarded reply stays small."
  (when-let* (((not my-go--warmed))
              ((get-buffer-window (current-buffer) t))
              (server (eglot-current-server))
              (pos (my-go--warmup-position)))
    (setq my-go--warmed t)
    (jsonrpc-async-request server :textDocument/completion
                           (save-excursion (goto-char pos) (eglot--CompletionParams))
                           :success-fn #'ignore :error-fn #'ignore :timeout-fn #'ignore)))

(defconst my-go--hooks
  '((before-change-functions . my-go--before-change)
    (after-change-functions . my-go--after-change)
    (kill-buffer-hook . my-go--reset)
    (completion-in-region-mode-hook . my-go--popup-closed)
    (post-command-hook . my-go--post-command)))

(defun my-go-completion-setup ()
  "Use asynchronous completion while Eglot manages a Go buffer."
  (when (derived-mode-p 'go-ts-mode)
    (my-go--reset)
    (if (not (eglot-managed-p))
        (progn
          (remove-hook 'completion-at-point-functions #'my-go-completion-at-point t)
          (pcase-dolist (`(,hook . ,fn) my-go--hooks) (remove-hook hook fn t))
          (corfu-mode -1)
          (mapc #'kill-local-variable
                '(corfu-auto corfu-auto-prefix corfu-auto-delay corfu-auto-trigger)))
      (remove-hook 'completion-at-point-functions #'eglot-completion-at-point t)
      (add-hook 'completion-at-point-functions #'my-go-completion-at-point nil t)
      (pcase-dolist (`(,hook . ,fn) my-go--hooks) (add-hook hook fn nil t))
      (setq-local corfu-auto t corfu-auto-prefix 1 corfu-auto-delay 0.05
                  corfu-auto-trigger ".")
      (corfu-mode 1)
      (my-go--warmup))))
(add-hook 'eglot-managed-mode-hook #'my-go-completion-setup)

(dolist (buffer (buffer-list))
  (with-current-buffer buffer (my-go-completion-setup)))

(provide 'my-go-completion)
;;; go-completion.el ends here
