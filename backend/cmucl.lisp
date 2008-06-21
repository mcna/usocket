;;;; $Id$
;;;; $URL$

;;;; See LICENSE for licensing information.

(in-package :usocket)

#+win32
(defun remap-for-win32 (z)
  (mapcar #'(lambda (x)
              (cons (mapcar #'(lambda (y)
                                (+ 10000 y))
                            (car x))
                    (cdr x)))
          z))

(defparameter +cmucl-error-map+
  #+win32
  (append (remap-for-win32 +unix-errno-condition-map+)
          (remap-for-win32 +unix-errno-error-map+))
  #-win32
  (append +unix-errno-condition-map+
          +unix-errno-error-map+))

(defun cmucl-map-socket-error (err &key condition socket)
  (let ((usock-err
         (cdr (assoc err +cmucl-error-map+ :test #'member))))
    (if usock-err
        (if (subtypep usock-err 'error)
            (error usock-err :socket socket)
          (signal usock-err :socket socket))
      (error 'unknown-error
             :socket socket
             :real-error condition))))

;; CMUCL error handling is brain-dead: it doesn't preserve any
;; information other than the OS error string from which the
;; error can be determined. The OS error string isn't good enough
;; given that it may have been localized (l10n).
;;
;; The above applies to versions pre 19b; 19d and newer are expected to
;; contain even better error reporting.
;;
;;
;; Just catch the errors and encapsulate them in an unknown-error
(defun handle-condition (condition &optional (socket nil))
  "Dispatch correct usocket condition."
  (typecase condition
    (ext::socket-error (cmucl-map-socket-error (ext::socket-errno condition)
                                               :socket socket
                                               :condition condition))))

(defun socket-connect (host port &key (element-type 'character) timeout)
  (when timeout
    (warn "SOCKET-CONNECT timeout not supported in CMUCL"))
  (let* ((socket))
    (setf socket
          (with-mapped-conditions (socket)
             (ext:connect-to-inet-socket (host-to-hbo host) port :stream)))
    (if socket
        (let* ((stream (sys:make-fd-stream socket :input t :output t
                                           :element-type element-type
                                           :buffering :full))
               ;;###FIXME the above line probably needs an :external-format
               (usocket (make-stream-socket :socket socket
                                            :stream stream)))
          usocket)
      (let ((err (unix:unix-errno)))
        (when err (cmucl-map-socket-error err))))))

(defun socket-listen (host port
                           &key reuseaddress
                           (reuse-address nil reuse-address-supplied-p)
                           (backlog 5)
                           (element-type 'character))
 (let* ((reuseaddress (if reuse-address-supplied-p reuse-address reuseaddress))
        (server-sock
         (with-mapped-conditions ()
           (apply #'ext:create-inet-listener
                  (append (list port :stream
                                :backlog backlog
                                :reuse-address reuseaddress)
                          (when (ip/= host *wildcard-host*)
                            (list :host
                                  (host-to-hbo host))))))))
   (make-stream-server-socket server-sock :element-type element-type)))

(defmethod socket-accept ((usocket stream-server-usocket) &key element-type)
  (with-mapped-conditions (usocket)
    (let* ((sock (ext:accept-tcp-connection (socket usocket)))
           (stream (sys:make-fd-stream sock :input t :output t
                                       :element-type (or element-type
                                                         (element-type usocket))
                                       :buffering :full)))
      (make-stream-socket :socket sock :stream stream))))

;; Sockets and socket streams are represented
;; by different objects. Be sure to close the
;; socket stream when closing a stream socket.
(defmethod socket-close ((usocket stream-usocket))
  "Close socket."
  (with-mapped-conditions (usocket)
    (close (socket-stream usocket))))

(defmethod socket-close ((usocket usocket))
  "Close socket."
  (with-mapped-conditions (usocket)
    (ext:close-socket (socket usocket))))

(defmethod get-local-name ((usocket usocket))
  (multiple-value-bind
      (address port)
      (ext:get-socket-host-and-port (socket usocket))
    (values (hbo-to-vector-quad address) port)))

(defmethod get-peer-name ((usocket stream-usocket))
  (multiple-value-bind
      (address port)
      (ext:get-peer-host-and-port (socket usocket))
    (values (hbo-to-vector-quad address) port)))

(defmethod get-local-address ((usocket usocket))
  (nth-value 0 (get-local-name usocket)))

(defmethod get-peer-address ((usocket stream-usocket))
  (nth-value 0 (get-peer-name usocket)))

(defmethod get-local-port ((usocket usocket))
  (nth-value 1 (get-local-name usocket)))

(defmethod get-peer-port ((usocket stream-usocket))
  (nth-value 1 (get-peer-name usocket)))


(defun lookup-host-entry (host)
  (multiple-value-bind
      (entry errno)
      (ext:lookup-host-entry host)
    (if entry
        entry
      ;;###The constants below work on *most* OSes, but are defined as the
      ;; constants mentioned in C
      (let ((exception
             (second (assoc errno
                            '((1 ns-host-not-found-error) ;; HOST_NOT_FOUND
                              (2 ns-no-recovery-error)    ;; NO_DATA
                              (3 ns-no-recovery-error)    ;; NO_RECOVERY
                              (4 ns-try-again))))))       ;; TRY_AGAIN
        (when exception
          (error exception))))))


(defun get-host-by-address (address)
  (handler-case (ext:host-entry-name
                 (lookup-host-entry (host-byte-order address)))
    (condition (condition) (handle-condition condition))))

(defun get-hosts-by-name (name)
  (handler-case (mapcar #'hbo-to-vector-quad
                        (ext:host-entry-addr-list
                         (lookup-host-entry name)))
    (condition (condition) (handle-condition condition))))

(defun get-host-name ()
  (unix:unix-gethostname))

(defun wait-for-input-internal (sockets &key timeout)
  (with-mapped-conditions ()
    (alien:with-alien ((rfds (alien:struct unix:fd-set)))
       (unix:fd-zero rfds)
       (dolist (socket sockets)
         (unix:fd-set (socket socket) rfds))
       (multiple-value-bind
           (secs musecs)
           (split-timeout (or timeout 1))
         (multiple-value-bind
             (count err)
             (unix:unix-fast-select (1+ (reduce #'max sockets
                                                :key #'socket))
                                    (alien:addr rfds) nil nil
                                    (when timeout secs) musecs)
           (if (<= 0 count)
               ;; process the result...
               (remove-if #'(lambda (x)
                              (not (unix:fd-isset (socket x) rfds)))
                          sockets)
             (progn
               ;;###FIXME generate an error, except for EINTR
               )))))))
