; -*- mode: lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; The toplevel function for the Trubanc application
;;;

(in-package :trubanc-client-web)

(defun toplevel-function ()
  (set-interactive-abort-process)
  (invoking-debugger-hook-on-interrupt
    (let ((*debugger-hook* (lambda (condition hook)
                             ;; Here on ctrl-c, SIGINT.
                             ;; Really should do a controlled shut-down
                             ;; of the web server, with a second hook
                             ;; to quit right away on a second ctlr-c
                             (declare (ignore condition hook))
                             (terpri)
                             (finish-output)
                             (quit))))
      (handler-case (toplevel-function-internal)
        (error (c)
          (if (typep c 'usage-error)
              (format t "~&~a~%" c)
              (format t "~&~a~%~a~%" c (backtrace-string)))
          (finish-output)
          (quit -1))))))

(defparameter *allowed-parameters*
  '((("-p" "--port") :port . t)
    ("--key" :key . t)
    ("--cert" :cert . t)
    ("--nonsslport" :nonsslport . t)
    #+loadswank
    ("--slimeport" :slimeport . t)))

(define-condition usage-error (simple-error)
  ())

(defun usage-error (app)
  (error 'usage-error
         :format-control
         "Usage is: ~a [-p port] [--key keyfile --cert certfile] [--nonsslport nonsslport]~a
port defaults to 8782, unless keyfile & certfile are included, then 8783.
If port defaults to 8783, then nonsslport defaults to 8782,
otherwise the application doesn't listen on a non-ssl port.
keyfile is the path to an SSL private key file.
certfile is the path to an SSL certificate file.
slimeport is a port on which to listen for a connection from the SLIME IDE."
         :format-arguments
         (list app (or #-loadswank "" " [--slimeport slimeport]"))))

(defun parse-args (&optional (args (command-line-arguments)))
  (let ((app (pop args))
        (res nil))
    (loop
       while args
       for switch = (pop args)
       for key-and-argp = (cdr (assoc switch *allowed-parameters*
                                  :test (lambda (x y)
                                          (member x
                                                  (if (listp y) y (list y))
                                                  :test #'string-equal))))
       for key = (car key-and-argp)
       for argp = (cdr key-and-argp)
       do
         (cond (argp
                (when (and argp (null args))
                  (usage-error app))
                (push (cons key (and argp (pop args))) res))
               (t (usage-error app))))
    (values (nreverse res) app)))

(defparameter *default-port-string* "8782")
(defparameter *default-ssl-port-string* "8783")

(defun toplevel-function-internal ()
  (run-startup-functions)
  (let (port keyfile certfile nonsslport slimeport)
    (multiple-value-bind (args app) (parse-args)
      (handler-case
          (setq keyfile (cdr (assoc :key args))
                certfile (cdr (assoc :cert args))
                port (parse-integer
                      (or (cdr (assoc :port args))
                          (if keyfile
                              *default-ssl-port-string*
                              *default-port-string*)))
                nonsslport (parse-integer
                            (or (cdr (assoc :nonsslport args))
                                (if (assoc :port args) "0" *default-port-string*)))
                slimeport (let ((str (cdr (assoc :slimeport args))))
                            (and str (parse-integer str))))
        (error () (usage-error app))))
    (when (xor keyfile certfile)
      (error "Both or neither required of --key & --cert"))
    (when keyfile
      (unless (and (probe-file keyfile) (probe-file certfile))
        (error "Key or cert file missing")))
    (when (eql 0 nonsslport) (setq nonsslport nil))
    #+loadswank
    (when slimeport
      (push (cons '*package* (find-package :trubanc))
            swank:*default-worker-thread-bindings*)
      (swank:create-server :port slimeport :dont-close t))
    slimeport                           ;no warning
    (handler-case
        (let ((url (format nil "http://localhost:~a/"
                           (or nonsslport port))))
          (trubanc-web-server
           nil
           :port port
           :ssl-privatekey-file keyfile
           :ssl-certificate-file certfile
           :forwarding-port nonsslport)
          (format t "Client web server started on port ~a.~%"
                  (or nonsslport port))
          (format t "Web address: ~a~%" url)
          (when (server-db-exists-p)
            (format t "REMEMBER TO LOG IN AS THE BANK TO START THE SERVER!!~%"))
          (finish-output)
          (browse-url url))
      (error (c)
        (format t "Error starting server on port ~d: ~a~%" port c)
        (finish-output)
        (quit -1))))
  (process-wait
   "Server shutdown"
   (lambda () (not (web-server-active-p)))))

(defun last-commit ()
  (ignore-errors
    (let* ((s #-windows (run-program "git" '("log") :output :stream)
	      #+windows (progn (run-program "git-log.bat" nil)
			       (open "git.log")))	   
	   (str (unwind-protect (read-line s)
		  (close s))))
      (when str
        ;; str = "commit <number>"
        (second (explode #\ (trim str)))))))

(defun target-suffix ()
  (or
   (progn
     #+darwinx86-target "dx86cl"
     #+darwinx8664-target "dx86cl64"
     #+freebsdx86-target "fx86cl"
     #+freebsdx8664-target "fx86cl64"
     #+linuxx86-target "lx86cl"
     #+linuxx8664-target "lx86cl64"
     #+win32-target "wx86cl.exe"
     #+win64-target "wx86cl64.exe")
   "app"))

(defun write-application-name (file &optional (name (application-name)))
  (with-open-file (s file :direction :output :if-exists :supersede)
    (write-string name s)))

(defun application-name ()
  (stringify (target-suffix) "trubanc-~a"))

(defun save-trubanc-application (&optional (filename (application-name)))
  (stop-web-server)
  (setq *last-commit* (last-commit))
  (setq *save-application-time* (get-unix-time))
  (save-application filename
                    :toplevel-function #'toplevel-function
                    :prepend-kernel t
                    :clear-clos-caches t))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Copyright 2009 Bill St. Clair
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions
;;; and limitations under the License.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
