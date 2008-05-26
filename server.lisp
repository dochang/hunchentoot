;;; -*- Mode: LISP; Syntax: COMMON-LISP; Package: CL-USER; Base: 10 -*-
;;; $Header: /usr/local/cvsrep/hunchentoot/server.lisp,v 1.43 2008/04/09 08:17:48 edi Exp $

;;; Copyright (c) 2004-2008, Dr. Edmund Weitz.  All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:

;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.

;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.

;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :hunchentoot)

(defclass server ()
  ((socket :accessor server-socket
           :documentation "The socket the server is listening on.")
   (port :initarg :port
         :documentation "The port the server is listening on.
See START-SERVER.")
   (address :initarg :address
            :documentation "The address the server is listening
on.  See START-SERVER.")
   (name :initarg :name
         :accessor server-name
         :documentation "The optional name of the server, a symbol.")
   (dispatch-table :initarg :dispatch-table
                   :accessor server-dispatch-table
                   :documentation "The dispatch-table used by this
server.  Can be NIL to denote that *META-DISPATCHER* should be called
instead.")
   (output-chunking-p :initarg :output-chunking-p
                      :reader server-output-chunking-p
                      :documentation "Whether the server may use output chunking.")
   (input-chunking-p :initarg :input-chunking-p
                     :reader server-input-chunking-p
                     :documentation "Whether the server may use input chunking.")
   (persistent-connections-p :initarg :persistent-connections-p
                             :accessor server-persistent-connections-p
                             :documentation "Whether the server
supports persistent connections, which is the default for threaded
servers.  If this property is false, Hunchentoot closes incoming
connections after having processed one request.  This is the default
for non-threaded servers.")
   (read-timeout :initarg :read-timeout
                 :reader server-read-timeout
                 :documentation "The connection timeout of the server,
specified in (fractional) seconds.  Connections that are idle for
longer than this time are closed by Hunchentoot.  The precise
semantics of this parameter is determined by the underlying Lisp's
implementation of socket timeouts.")
   (write-timeout :initarg :write-timeout
                 :reader server-write-timeout
                 :documentation "The connection timeout of the server,
specified in (fractional) seconds.  The precise semantics of this
parameter is determined by the underlying Lisp's implementation of
socket timeouts.")
   (connection-manager :initarg :connection-manager
                       :initform nil
                       :reader server-connection-manager
                       :documentation "The connection manager that is
responsible for listening to new connections and scheduling them for
execution.")
   (lock :initform (bt:make-lock)
         :reader server-lock
         :documentation "A lock which is used to make sure that
we can shutdown the server cleanly.")
   (server-shutdown-p :initform nil
                      :accessor server-shutdown-p
                      :documentation "Flag that makes the server
shutdown itself when set to something other than NIL.")
   (access-logger :initarg :access-logger
                  :accessor server-access-logger
                  :documentation "Function to call to log access to
the server.  The function must accept the RETURN-CODE, CONTENT and
CONTENT-LENGTH keyword arguments which are used to pass in additional
information about the request to log.  In addition, it can use the
standard request accessor functions that are available to handler
functions to find out more information about the request.  This slot
defaults to the LOG-ACCESS function which logs the information to a
file in a format that can be parsed by most Apache log analysis
tools.")
   (message-logger :initarg :message-logger
                   :accessor server-message-logger
                   :documentation "Function to call to log messages by
the server.  It must accept a severity level for the message, which
will be one of (:NOTICE :INFO :WARNING), a format string and an
arbitary number of formatting arguments.  This slot defaults to the
LOG-MESSAGE function which writes writes the information to a file."))
  (:default-initargs
    :address nil
    :port 80
    :name (gensym)
    :output-chunking-p t
    :input-chunking-p t
    :dispatch-table nil
    :access-logger #'log-access
    :message-logger #'log-message)
  (:documentation "An object of this class contains all relevant
information about a running Hunchentoot server instance."))

(defmethod initialize-instance :after ((server server)
                                       &key connection-manager-class
                                            connection-manager-arguments
                                            (threaded bt:*supports-threads-p* threaded-specified-p)
                                            (persistent-connections-p threaded persistent-connections-specified-p)
                                            (connection-timeout *default-connection-timeout* connection-timeout-provided-p)
                                            (read-timeout nil read-timeout-provided-p)
                                            (write-timeout nil write-timeout-provided-p))
  "The CONNECTION-MANAGER-CLASS and CONNECTION-MANAGER-ARGUMENTS
arguments to the creation of a server instance determine the
connection manager instance that is created.  THREADED is the user
friendly version of the CONNECTION-MANAGER-CLASS option.  If it is
NIL, an unthreaded connection manager is used.  It is an error to
specify both THREADED and a CONNECTION-MANAGER-CLASS argument.

The PERSISTENT-CONNECTIONS-P keyword argument defaults to the value of
the THREADED keyword argument but can be overridden.

If a neither READ-TIMEOUT nor WRITE-TIMEOUT are specified by the user,
the server's read and write timeouts default to the CONNECTION-TIMEOUT
value.  If either of READ-TIMEOUT or WRITE-TIMEOUT is specified,
CONNECTION-TIMEOUT is not used and may not be supplied."
  (declare (ignore read-timeout write-timeout))
  (when (and threaded-specified-p connection-manager-class)
    (error "can't use both THREADED and CONNECTION-MANAGER-CLASS arguments"))
  (unless persistent-connections-specified-p
    (setf (server-persistent-connections-p server) persistent-connections-p))
  (unless (server-connection-manager server)
    (setf (slot-value server 'connection-manager)
          (apply #'make-instance
                 (or connection-manager-class
                     (if threaded
                         'one-thread-per-connection-manager
                         'single-threaded-connection-manager))
                 :server server
                 connection-manager-arguments)))
  (if (or read-timeout-provided-p write-timeout-provided-p)
      (when connection-timeout-provided-p
        (error "can't have both CONNECTION-TIMEOUT and either of READ-TIMEOUT and WRITE-TIMEOUT."))
      (setf (slot-value server 'read-timeout) connection-timeout
            (slot-value server 'write-timeout) connection-timeout)))

(defgeneric server-ssl-p (server)
  (:documentation "Return non-NIL if SERVER is an SSL server")
  (:method ((server t))
    nil))

(defun ssl-p (&optional (server *server*))
  (server-ssl-p server))

(defgeneric server-chunking-p (server)
  (:documentation "Return non-NIL if the SERVER is in chunking mode
\(either for input or output)")
  (:method (server)    
    (or (server-input-chunking-p server)
        (server-output-chunking-p server))))

(defmethod print-object ((server server) stream)
  (print-unreadable-object (server stream :type t)
    (format stream "host ~A port ~A"
            (or (server-address server) "*") (server-port server))))

(defun server-address (&optional (server *server*))
  "Returns the address at which the current request arrived."
  (slot-value server 'address))

(defun server-port (&optional (server *server*))
  "Returns the port at which the current request arrived."
  (slot-value server 'port))

(defgeneric start (server)
  (:documentation "Start the SERVER so that it begins accepting
connections.")
  (:method ((server server))
    (execute-listener (server-connection-manager server))))

(defgeneric stop (server)
  (:documentation "Stop the SERVER so that it does no longer accept requests.")
  (:method ((server server))
    (setf (server-shutdown-p server) t)
    (shutdown (server-connection-manager server))))

(defun start-server (&rest args
                     &key port address dispatch-table name
                     threaded
                     input-chunking-p connection-timeout
                     persistent-connections-p
                     read-timeout write-timeout
                     setuid setgid
                     #-:hunchentoot-no-ssl #-:hunchentoot-no-ssl #-:hunchentoot-no-ssl
                     ssl-certificate-file ssl-privatekey-file ssl-privatekey-password
                     access-logger)
  ;; Except for ssl-certificate-file, which is used to determine
  ;; whether SSL is desired, all arguments are here so that the lambda
  ;; list is self documenting and ignored otherwise
  (declare (ignore port address dispatch-table name
                   threaded
                   input-chunking-p connection-timeout
                   persistent-connections-p
                   setuid setgid
                   read-timeout write-timeout
                   #-:hunchentoot-no-ssl #-:hunchentoot-no-ssl
                   ssl-privatekey-file ssl-privatekey-password
                   access-logger))
  "Starts a Hunchentoot server and returns the SERVER object \(which
can be stopped with STOP-SERVER).  PORT is the port the server will be
listening on - the default is 80 \(or 443 if SSL information is
provided).  If ADDRESS is a string denoting an IP address, then the
server only receives connections for that address.  This must be one
of the addresses associated with the machine and allowed values are
host names such as \"www.nowhere.com\" and address strings like
\"204.71.177.75\".  If ADDRESS is NIL, then the server will receive
connections to all IP addresses on the machine.  This is the default.

DISPATCH-TABLE can either be a dispatch table which is to be used by
this server or NIL which means that at request time *META-DISPATCHER*
will be called to retrieve a dispatch table.

NAME should be a symbol which can be used to name the server.  This
name can utilized when defining \"easy handlers\" - see
DEFINE-EASY-HANDLER.  The default name is an uninterned symbol as
returned by GENSYM.

If INPUT-CHUNKING-P is true, the server will accept request bodies
without a `Content-Length' header if the client uses chunked transfer
encoding.

If PERSISTENT-CONNECTIONS-P is true, the server will support
persistent connections and process multiple requests on one incoming
connection.  If it is false, Hunchentoot will close every connection
after one request has been processed.  This argument defaults to true
for threaded and false for non-threaded servers.

CONNECTION-TIMEOUT specifies the connection timeout for client
connections in \(fractional) seconds - use NIL for no timeout at all.
This parameter limits the time that Hunchentoot will wait for data to
be received from or sent to a client.  The details of how this
parameter works is implementation specific.

READ-TIMEOUT and WRITE-TIMEOUT specify implementation specific
timeouts for reading from and writing to client sockets.  The exact
semantics of these two parameters are Lisp implementation specific,
and not all implementations provide for separate read and write
timeout parameter setting.

CONNECTION-MANAGER-CLASS specifies the name of the class to instantiate
for managing how connections are mapped to threads.  You don't normally
want to specify this argument unless you want to have non-standard
threading behavior.   See the documentation for more information.

On Unix you can use SETUID and SETGID to change the UID and GID of the
process directly after the server has been started.  \(You might want
to do this if you're using a privileged port like 80.)  SETUID and
SETGID can be integers \(the actual IDs) or strings \(for the user and
group name respectively).

ACCESS-LOGGER is a function that is called by the server to log
requests.  It defaults to the function HUNCHENTOOT::LOG-ACCESS and can
be overriden for individual servers.  The function needs to accept the
RETURN-CODE, CONTENT and CONTENT-LENGTH keyword arguments which are
bound by the server to the HTTP return code, the CONTENT sent back to
the client and the number of bytes sent back in the request body to
the client.  HUNCHENTOOT::LOG-ACCESS calls the generic logging
function specified by LOGGER.

If you want your server to use SSL you must provide the pathname
designator\(s) SSL-CERTIFICATE-FILE for the certificate file and
optionally SSL-PRIVATEKEY-FILE for the private key file, both files
must be in PEM format.  If you only provide the value for
SSL-CERTIFICATE-FILE it is assumed that both the certificate and the
private key are in one file.  If your private key needs a password you
can provide it through the SSL-PRIVATEKEY-PASSWORD keyword argument,
but this works only on LispWorks - for other Lisps the key must not be
associated with a password."
  (unless (boundp '*session-secret*)
    (reset-session-secret))
  #+:hunchentoot-no-ssl
  (when ssl-certificate-file
    (error "Hunchentoot SSL support not compiled in"))
  (let ((server (apply #'make-instance
                       #-:hunchentoot-no-ssl
                       (if ssl-certificate-file 'ssl-server 'server)
                       #+:hunchentoot-no-ssl
                       'server
                       args)))
    (start server)
    server))

(defun stop-server (server)
  "Stops the Hunchentoot server SERVER."
  (stop server))

;; Connection manager API

(defconstant +new-connection-wait-time+ 2
  "Time in seconds to wait for a new connection to arrive before performing a cleanup run.")

(defgeneric listen-for-connections (server)
  (:documentation "Set up a listen socket for the given SERVER and
listen for incoming connections.  In a loop, accept a connection and
dispatch it to the server's connection manager object for processing
using HANDLE-INCOMING-CONNECTION.")
  (:method ((server server))
    (usocket:with-socket-listener (listener
                                   (or (server-address server)
                                       usocket:*wildcard-host*)
                                   (server-port server)
                                   :reuseaddress t
                                   :element-type '(unsigned-byte 8))
      (do ((new-connection-p (usocket:wait-for-input listener :timeout +new-connection-wait-time+)
                             (usocket:wait-for-input listener :timeout +new-connection-wait-time+)))
          ((server-shutdown-p server))
        (when new-connection-p
          (let ((client-connection (usocket:socket-accept listener)))
            (when client-connection
              (set-timeouts client-connection
                            (server-read-timeout server)
                            (server-write-timeout server))
              (handle-incoming-connection (server-connection-manager server)
                                          client-connection))))))))

(defgeneric initialize-connection-stream (server stream)
  (:documentation "Wrap the given STREAM with all the additional
stream classes to support the functionality required by SERVER")
  (:method (server stream)
    ;; wrap with chunking-enabled stream if necessary
    (when (server-chunking-p server)
      (setq stream (make-chunked-stream stream)))
    ;; now wrap with flexi stream with "faithful" external format
    (setq stream
          (make-flexi-stream stream :external-format +latin-1+))))

(defgeneric reset-connection-stream (server stream)
  (:documentation "Reset the given STREAM so that it can be used to
process the next request, SERVER is the server that this stream
belongs to, which determines what to do to reset.  This generic
function is called after a request has been processed.")
  (:method (server stream)
    ;; reset to "faithful" format on each iteration
    ;; and reset bound of stream as well
    (setf (flexi-stream-external-format stream) +latin-1+
          (flexi-stream-bound stream) nil)
    ;; turn chunking off at this point
    (when (server-chunking-p server)
      (setf (chunked-stream-output-chunking-p (flexi-stream-stream stream)) nil
            (chunked-stream-input-chunking-p (flexi-stream-stream stream)) nil))))

(defgeneric process-connection (server socket)

  (:documentation "This function is called by the connection manager
when a new client connection has been established.  Arguments are the
SERVER object and a usocket socket stream object in SOCKET.  It reads
the request headers and hands over to PROCESS-REQUEST.  This is done
in a loop until the stream has to be closed or until a connection
timeout occurs.")

  (:method :around (server socket)
    "The around method on process-connection does the error handling"
    (declare (ignore server socket))
    (handler-bind ((error
                    ;; abort if there's an error which isn't caught inside
                    (lambda (cond)
                      (log-message *lisp-errors-log-level*
                                   "Error while processing connection: ~A" cond)                    
                      (return-from process-connection)))
                   (warning
                    ;; log all warnings which aren't caught inside
                    (lambda (cond)
                      (log-message *lisp-warnings-log-level*
                                   "Warning while processing connection: ~A" cond))))
      (call-next-method)))

  (:method (server socket)
    (let ((stream (initialize-connection-stream server (usocket:socket-stream socket))))
      (unwind-protect
           (progn
             ;; Process requests until either the server is shut down,
             ;; *close-hunchentoot-stream* has been set to t by the
             ;; handler or the peer fails to send a request.
             (do ((*close-hunchentoot-stream* t)
                  (*hunchentoot-stream* stream)
                  (*server* server))
                 ((server-shutdown-p server))
               (multiple-value-bind (headers-in method url-string server-protocol)
                   (get-request-data stream)
                 ;; check if there was a request at all
                 (unless method
                   (return))
                 ;; Bind request-special variables, then process the request
                 (let ((*reply* (make-instance 'reply))
                       (*session* nil))
                   (process-request
                    (make-instance 'request
                                   :remote-addr (usocket:vector-quad-to-dotted-quad (usocket:get-peer-address socket))
                                   :remote-port (usocket:get-peer-port socket)
                                   :headers-in headers-in
                                   :content-stream stream
                                   :method method
                                   :uri url-string
                                   :server-protocol server-protocol)))
                 (force-output stream)
                 (reset-connection-stream server stream)
                 (when *close-hunchentoot-stream*
                   (return)))))
        (when stream
          ;; As we are at the end of the request here, we ignore all
          ;; errors that may occur while flushing and/or closing the
          ;; stream.
          (ignore-errors
            (force-output stream)
            (close stream :abort t)))))))

(defun process-request (request)
  "This function is called by PROCESS-CONNECTION after the incoming
headers have been read.  It sets up the REQUEST and REPLY objects,
dispatches to a handler, and finally sends the output to the client
using START-OUTPUT.  If all goes as planned, the function returns T."
  (let (*tmp-files* *headers-sent*)
    (unwind-protect
        (progn
          (when (server-input-chunking-p *server*)
            (let ((transfer-encodings (header-in :transfer-encoding request)))
              (when transfer-encodings
                (setq transfer-encodings
                      (split "\\s*,\\*" transfer-encodings)))
              (when (member "chunked" transfer-encodings :test #'equalp)
                ;; turn chunking on before we read the request body
                (setf (chunked-stream-input-chunking-p 
                       (flexi-stream-stream *hunchentoot-stream*)) t))))
          (let* ((*request* request)
                 (*dispatch-table* (or (server-dispatch-table *server*)
                                       (funcall *meta-dispatcher* *server*)))
                 backtrace)
            (multiple-value-bind (body error)
                (catch 'handler-done
                  (handler-bind ((error
                                  (lambda (cond)
                                    ;; only generate backtrace if needed
                                    (setq backtrace
                                          (and (or (and *show-lisp-errors-p*
                                                        *show-lisp-backtraces-p*)
                                                   (and *log-lisp-errors-p*
                                                        *log-lisp-backtraces-p*))
                                               (get-backtrace cond)))
                                    (when *log-lisp-errors-p*
                                      (log-message *lisp-errors-log-level*
                                                   "~A~:[~*~;~%~A~]"
                                                   cond
                                                   *log-lisp-backtraces-p*
                                                   backtrace))
                                    ;; if the headers were already sent
                                    ;; the error happens within the body
                                    ;; and we have to close the stream
                                    (when *headers-sent*
                                      (setq *close-hunchentoot-stream* t))
                                    (throw 'handler-done
                                           (values nil cond))))
                                 (warning
                                  (lambda (cond)
                                    (when *log-lisp-warnings-p*
                                      (log-message *lisp-warnings-log-level*
                                                   "~A~:[~*~;~%~A~]"
                                                   cond
                                                   *log-lisp-backtraces-p*
                                                   backtrace)))))
                    ;; skip dispatch if bad request
                    (when (eql (return-code) +http-ok+)
                      ;; now do the work
                      (dispatch-request *dispatch-table*))))
              (when error
                (setf (return-code *reply*)
                      +http-internal-server-error+))
              (start-output (cond ((and error *show-lisp-errors-p*)
                                   (format nil "<pre>~A~:[~*~;~%~%~A~]</pre>"
                                           (escape-for-html (format nil "~A" error))
                                           *show-lisp-backtraces-p*
                                           (escape-for-html (format nil "~A" backtrace))))
                                  (error
                                   "An error has occured")
                                  (t body))))
            t))
      (dolist (path *tmp-files*)
        (when (and (pathnamep path) (probe-file path))
          ;; The handler may have chosen to (re)move the uploaded
          ;; file, so ignore errors that happen during deletion.
          (ignore-errors
            (delete-file path)))))))
