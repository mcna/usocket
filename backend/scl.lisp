;;;; $Id: scl.lisp$
;;;; $URL: svn://common-lisp.net/project/usocket/svn/usocket/trunk/backend/scl.lisp $

;;;; See LICENSE for licensing information.

(in-package :usocket)

(defparameter +scl-error-map+
  (append +unix-errno-condition-map+
          +unix-errno-error-map+))

(defun scl-map-socket-error (err &key condition socket)
  (let ((usock-err (cdr (assoc err +scl-error-map+ :test #'member))))
    (cond (usock-err
       (if (subtypep usock-err 'error)
           (error usock-err :socket socket)
           (signal usock-err :socket socket)))
      (t
       (error 'unknown-error
          :socket socket
          :real-error condition)))))

(defun handle-condition (condition &optional (socket nil))
  "Dispatch correct usocket condition."
  (etypecase condition
    (ext::socket-error
     (scl-map-socket-error (ext::socket-errno condition)
               :socket socket
               :condition condition))
    (error
     (error 'unknown-error
        :real-condition condition
        :socket socket))))

(defun socket-connect (host port &key (element-type 'character))
  (let* ((socket (with-mapped-conditions ()
                  (ext:connect-to-inet-socket (host-to-hbo host) port
                                              :kind :stream)))
         (stream (sys:make-fd-stream socket :input t :output t
                                     :element-type element-type
                                     :buffering :full)))
    (make-stream-socket :socket socket :stream stream)))

(defun socket-listen (host port &key reuseaddress (backlog 5))
  (let* ((host (if (eql host *wildcard-host*)
                  0
                  (host-to-hbo host)))
        (server-sock (ext:create-inet-listener port :stream
                                               :host host
                                               :reuse-address reuseaddress
                                               :backlog backlog)))
   (make-stream-server-socket server-sock)))

(defmethod socket-accept ((usocket stream-server-usocket))
  (let* ((sock (ext:accept-tcp-connection (socket usocket)))
         (stream (sys:make-fd-stream sock :input t :output t
                                     :element-type (element-type usocket)
                                     :buffering :full)))
    (make-stream-socket :socket sock :stream stream)))

(defmethod socket-close ((usocket usocket))
  "Close socket."
  (with-mapped-conditions (usocket)
    (ext:close-socket (socket usocket))))

(defmethod get-local-name ((usocket usocket))
  (multiple-value-bind (address port)
      (with-mapped-conditions (usocket)
        (ext:get-socket-host-and-port (socket usocket)))
    (values (hbo-to-vector-quad address) port)))

(defmethod get-peer-name ((usocket usocket))
  (multiple-value-bind (address port)
      (with-mapped-conditions (usocket)
        (ext:get-peer-host-and-port (socket usocket)))
    (values (hbo-to-vector-quad address) port)))

(defmethod get-local-address ((usocket usocket))
  (nth-value 0 (get-local-name usocket)))

(defmethod get-peer-address ((usocket usocket))
  (nth-value 0 (get-peer-name usocket)))

(defmethod get-local-port ((usocket usocket))
  (nth-value 1 (get-local-name usocket)))

(defmethod get-peer-port ((usocket usocket))
  (nth-value 1 (get-peer-name usocket)))


(defun get-host-by-address (address)
  (multiple-value-bind (host errno)
      (ext:lookup-host-entry (host-byte-order address))
    (cond (host
           (ext:host-entry-name host))
          (t
           (let ((condition (cdr (assoc errno +unix-ns-error-map+))))
             (cond (condition
                    (error condition :host-or-ip address))
                   (t
                    (error 'ns-unknown-error :host-or-ip address
                           :real-error errno))))))))

(defun get-hosts-by-name (name)
  (multiple-value-bind (host errno)
      (ext:lookup-host-entry name)
    (cond (host
           (mapcar #'hbo-to-vector-quad
                   (ext:host-entry-addr-list host)))
          (t
           (let ((condition (cdr (assoc errno +unix-ns-error-map+))))
             (cond (condition
                    (error condition :host-or-ip name))
                   (t
                    (error 'ns-unknown-error :host-or-ip name
                           :real-error errno))))))))
