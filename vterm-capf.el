;;; vterm-capf.el --- Vterm completion-at-point facilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Gong Qijian <gongqijian@gmail.com>

;; Author: Gong Qijian <gongqijian@gmail.com>
;; Created: 2022/11/19
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1") (vterm "0.0.1"))
;; URL: https://github.com/twlz0ne/vterm-capf
;; Keywords: completion, shell

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Vterm completion-at-point facilities.

;; See README for more information.

;;; Code:

(require 'cl-lib)
(require 'vterm)

(defvar vterm-capf--shell-completions-cache nil
  "Cache of shell completions.")

(defvar vterm-capf--last-point nil
  "Point before send key.")

(defvar vterm-capf-shell-completion-command "compgen -A function -ac"
  "Command to generate shell completions.")

(defun vterm-capf-message (&rest args)
  ;; (let ((inhibit-message t))
  ;;   (apply #'message args))
  )

(defun vterm-capf--fetch-shell-completions (&optional force)
  "Return shell completions."
  (when (or force (not vterm-capf--shell-completions-cache))
    (setq vterm-capf--shell-completions-cache
          (split-string (shell-command-to-string
                         vterm-capf-shell-completion-command))))
  vterm-capf--shell-completions-cache)

(defun vterm-capf-in-region (beg end)
  "Complete the text between BEG and END."
  (let ((input (downcase (buffer-substring-no-properties beg end)))
        cands)
    (mapc
     (lambda (cand)
       (when (string-prefix-p input (downcase cand))
         (push cand cands)))
     (vterm-capf--fetch-shell-completions))
    (list beg end (reverse cands))))

(defun vterm-capf-at-point ()
  "Function for `completion-at-point-functions' in `vterm-mode'."
  (interactive)
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (vterm-capf-in-region (car bounds) (cdr bounds)))))

(defun vterm-capf--advice-inhibit-read-only (&rest args)
  "Advice to temporary inhibit buffer-read-only for `vterm-mode'."
  (if (derived-mode-p 'vterm-mode)
      (let (buffer-read-only)
        (apply args))
    (apply args)))



(defvar vterm-capf--post-command-timer nil "Post command timer.")

(defvar vterm-capf-abort-commands '(vterm-send-C-a
                                    vterm-send-C-e
                                    vterm-send-C-b
                                    vterm-send-C-f
                                    vterm-send-meta-backspace)
  "The keys used to abort completion.")

;;; Company

(defun vterm-capf--advice-company-idle-begin (origfn buf win tick pos)
  "Advice around `company-idle-begin'."
  (if (derived-mode-p 'vterm-mode)
      (funcall origfn buf win (buffer-chars-modified-tick) (point))
    (funcall origfn buf win tick pos)))

(defun vterm-capf--insert-company-candidate (candidate)
  "Advice override `company--insert-candidate' to insert CANDIDATE."
  (when (> (length candidate) 0)
    (setq candidate (substring-no-properties candidate))
    ;; XXX: Return value we check here is subject to change.
    (if (eq (company-call-backend 'ignore-case) 'keep-prefix)
        (vterm-insert (company-strip-prefix candidate))
      (unless (equal company-prefix candidate)
        (let ((bounds (bounds-of-thing-at-point 'symbol))
              (del-start (- (point) (length company-prefix) 1)))
          (vterm-delete-region (car bounds) (point))
          (vterm-insert candidate))))))

(defun vterm-capf--advice-company--insert-candidate (&rest args)
  (if (derived-mode-p 'vterm-mode)
      (let (buffer-read-only)
        (vterm-capf--insert-company-candidate (car (last args))))
    (apply args)))

(defun vterm-capf--advice-company-preview-show-at-point (&rest args)
  "Advice around `company-preview-show-at-point-advice'."
  (if (derived-mode-p 'vterm-mode)
      (progn
        (company-preview-hide)
        (apply 'run-with-timer 0.1 nil
               (lambda (origfn pos completion)
                 (vterm-capf-message "==> [vterm-capf--advice-company-preview-show-at-point] 1")
                 (let ((buffer-read-only t)
                       (inhibit-message t)
                       (company-point (point))
                       (company-prefix (thing-at-point 'symbol)))
                   (unless (string= completion company-prefix)
                     (funcall origfn (point) completion))))
               args))
    (vterm-capf-message "==> [vterm-capf--advice-company-preview-show-at-point] 2")
    (apply args)))

(defun vterm-capf--advice-company--continue (&rest args)
  (let ((company-point (if (and (derived-mode-p 'vterm-mode)
                                (eq this-command 'vterm-send-backspace))
                           ;; Let `company-calculate-candidates' to be execute
                           ;; when `backspace' be pressed.
                           (point)
                         company-point)))
    (apply args)))

;;; Corfu

(defun vterm-capf--advice-corfu--auto-post-command (&rest args)
  "Advice around `corfu--auto-post-command'."
  (vterm-capf-message "==> [vterm-capf--advice-corfu--auto-post-command] this-command: %s input: %s" this-command corfu--input)
  (if (derived-mode-p 'vterm-mode)
    (let (buffer-read-only)
      (apply args))
    (apply args)))

(defun vterm-capf--advice-corfu--exhibit (&rest args)
  "Advice around `corfu--exhibit'."
  (let ((corfu-quit-no-match
         (if (eq this-command 'corfu-complete)
             t ;; Inhibit `No match'.
           corfu-quit-no-match)))
    (apply args)))

(defun vterm-capf--advice-corfu--auto-complete (origfn tick)
  "Advice around `corfu--auto-complete'."
  (if (derived-mode-p 'vterm-mode)
      (funcall origfn (corfu--auto-tick))
    (funcall origfn tick)))

(defun vterm-capf--advice-corfu-complete (&rest args)
  "Advice around `corfu-complete'."
  (if (derived-mode-p 'vterm-mode)
      (let (buffer-read-only)
        (cl-letf (((symbol-function 'completion--replace)
                   (lambda (beg end newstr)
                     (vterm-capf-message "==> [completion--replace@] beg: %s end: %s newstr: %s" beg end newstr)
                     (let (buffer-read-only)
                       (vterm-insert (substring newstr (- end beg)))))))
          (apply args)))
    (apply args)))

(defun vterm-capf--invoke-company (this-command)
  (let ((buffer-read-only nil)
        (this-command this-command)
        (company-prefix (thing-at-point 'symbol))
        (company-backend 'company-capf) ;; Avoid void-function error in `company-call-backend-raw'.
        (company-begin-commands
         (append (if (eq this-command 'vterm--self-insert)
                     (list this-command)
                   nil)
                 company-begin-commands)))
    (vterm-capf-message "==> [vterm-send-key@after][1] this-command: %s prefix: %s" this-command company-prefix)
    (company-post-command)))

(defun vterm-capf--invoke-corfu (this-command)
  ;; (completion-at-point)
  (let ((this-command this-command)
        (corfu-auto-commands (list this-command))
        (completion-in-region--data
         (when completion-in-region--data
           (pcase-let ((`(,_beg ,end ,table ,pred) completion-in-region--data))
             (save-excursion
               (goto-char (1- end))
               (list (copy-marker (car (bounds-of-thing-at-point 'symbol)))
                     (copy-marker (point) t)
                     table
                     pred))))))
    (vterm-capf-message "==> [vterm-capf--invoke-corfu] this-command: %s" this-command)
    (vterm-capf-message "==> [vterm-capf--invoke-corfu] beg: %s end: %s" (nth 0 completion-in-region--data) (nth 1 completion-in-region--data))
    (corfu--post-command)))

(defun vterm-capf--advice-before-vterm-send-key (&rest _)
  (setq vterm-capf--last-point (point)))

(defun vterm-capf--advice-after-vterm-send-key (&rest _)
  "Advice after `vterm-send-key'."
  (vterm-capf-message "\n==> [vterm-send-key@after] this-command: %s input: %s"
                      this-command (or (bound-and-true-p company-prefix) (bound-and-true-p corfu--input)))
  (cond
   ((memq this-command vterm-capf-abort-commands)
    (cl-case vterm-capf-frontend
      (company
       (company-abort))
      (corfu
       (corfu-quit))))
   (t
    (let ((fn (cl-case vterm-capf-frontend
                (company 'vterm-capf--invoke-company)
                (corfu 'vterm-capf--invoke-corfu))))
      (when fn
        (when vterm-capf--post-command-timer
          (cancel-timer vterm-capf--post-command-timer)
          (setq vterm-capf--post-command-timer nil))
        (setq vterm-capf--post-command-timer
              (run-with-timer 0.1 nil fn this-command)))))))



(defvar vterm-capf-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-i") #'completion-at-point)
    map)
  "Keymap for `vterm-capf-mode'.")

(defcustom vterm-capf-frontend nil
  "Frontend of vterm capf."
  :group 'vterm-capf
  :type '(choice
          (const :tag "None" nil)
          (const :tag "Company" company)
          (const :tag "Corfu" corfu)))

(defun vterm-capf-frontend-setup (frontend)
  "Setup frontend."
  (cond
   ((eq frontend 'company)
    (cond
     (vterm-capf-mode
      (advice-add 'company-idle-begin :around #'vterm-capf--advice-company-idle-begin)
      (advice-add 'company-auto-begin :around #'vterm-capf--advice-inhibit-read-only)
      (advice-add 'company-preview-show-at-point :around #'vterm-capf--advice-company-preview-show-at-point)
      (advice-add 'company--continue :around #'vterm-capf--advice-company--continue)
      (advice-add 'company--insert-candidate :around #'vterm-capf--advice-company--insert-candidate))
     (t
      (advice-remove 'company-idle-begin #'vterm-capf--advice-company-idle-begin)
      (advice-remove 'company-auto-begin #'vterm-capf--advice-inhibit-read-only)
      (advice-remove 'company-preview-show-at-point #'vterm-capf--advice-company-preview-show-at-point)
      (advice-remove 'company--continue #'vterm-capf--advice-company--continue)
      (advice-remove 'company--insert-candidate #'vterm-capf--advice-company--insert-candidate))))
   ((eq frontend 'corfu)
    (cond
     (vterm-capf-mode
      (advice-add 'corfu--auto-post-command :around #'vterm-capf--advice-corfu--auto-post-command)
      (advice-add 'corfu--auto-complete :around #'vterm-capf--advice-corfu--auto-complete)
      (advice-add 'corfu--exhibit :around #'vterm-capf--advice-corfu--exhibit)
      (advice-add 'corfu-complete :around #'vterm-capf--advice-corfu-complete))
     (t
      (advice-remove 'corfu--auto-post-command #'vterm-capf--advice-corfu--auto-post-command)
      (advice-remove 'corfu--auto-complete #'vterm-capf--advice-corfu--auto-complete)
      (advice-remove 'corfu--exhibit #'vterm-capf--advice-corfu--exhibit)
      (advice-remove 'corfu-complete #'vterm-capf--advice-corfu-complete))))))

(define-minor-mode vterm-capf-mode
  "Toggle vterm capf mode on or off."
  :lighter " VTermCAPF"
  :global nil
  (if vterm-capf-mode
      (progn
        (add-hook 'completion-at-point-functions 'vterm-capf-at-point nil 'local)
        (advice-add 'completion-at-point :around #'vterm-capf--advice-inhibit-read-only)
        (advice-add 'vterm-send-key :before #'vterm-capf--advice-before-vterm-send-key)
        (advice-add 'vterm-send-key :after #'vterm-capf--advice-after-vterm-send-key))
    (remove-hook 'completion-at-point-functions 'vterm-capf-at-point 'local)
    (advice-remove 'completion-at-point #'vterm-capf--advice-inhibit-read-only)
    (advice-remove 'vterm-send-key #'vterm-capf--advice-before-vterm-send-key)
    (advice-remove 'vterm-send-key #'vterm-capf--advice-after-vterm-send-key))
  (vterm-capf-frontend-setup vterm-capf-frontend))

(provide 'vterm-capf)

;;; vterm-capf.el ends here
