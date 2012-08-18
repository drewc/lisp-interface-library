;;; -*- Mode: Lisp ; Base: 10 ; Syntax: ANSI-Common-Lisp -*-
;;;;; Plumbing to Define Interfaces

#+xcvb (module (:depends-on ("interface/package")))

(in-package :interface)

;; Definitions used by define-interface and its clients.
(eval-when (:compile-toplevel :load-toplevel :execute)

  (defclass interface-class (standard-class)
    ((generics :initform (make-hash-table :test 'eql) :accessor interface-generics)))

  (defmethod closer-mop:validate-superclass
      ((class interface-class) (super-class standard-class))
    t)

  (defun memberp (list &rest keys &key test test-not key)
    (declare (ignore test test-not key))
    (lambda (x) (apply 'member x list keys)))

  (defun number-of-required-arguments (lambda-list)
    (or (position-if (memberp '(&optional &rest &key &environment &aux)) lambda-list)
        (length lambda-list)))

  (defun normalize-gf-io (lambda-list values in out)
    (let ((in (ensure-list in))
          (out (ensure-list out))
          (maxin (number-of-required-arguments lambda-list))
          (maxout (number-of-required-arguments values))
          (lin (length in))
          (lout (length out)))
      (assert (<= 1 maxin))
      (cond
        ((< lin lout) (appendf in (make-list (- lout lin))))
        ((< lout lin) (appendf out (make-list (- lin lout)))))
      (loop :for i :in in :for o :in out :collect
        (let ((i (etypecase i
                   (null (assert (integerp o)) i)
                   (integer (assert (< 0 i maxin)) i)
                   (symbol (or (position i lambda-list :end maxin)
                               (error "~S not found in required arguments of lambda-list ~S" i lambda-list)))))
              (o (etypecase o
                   (boolean o)
                   (integer (assert (< -1 o maxout)) o)
                   (symbol (or (position o values :end maxout)
                               (error "~S not found in required arguments of values ~S" i values))))))
            (list i o)))))

  (defun register-interface-generic
      (class name &rest keys &key lambda-list values in out)
    (setf (gethash name (interface-generics (find-class class)))
          (acons :effects (normalize-gf-io lambda-list values in out) keys))
    (values))

  (defun interface-direct-generics (interface)
    (loop :for name :being :the :hash-key :of (interface-generics interface)
      :collect name))

  (defgeneric all-superclasses (classes)
    (:method ((symbol symbol))
      (all-superclasses (find-class symbol)))
    (:method ((class class))
      (closer-mop:class-precedence-list class))
    (:method ((classes cons))
      (remove-duplicates
       (mapcan #'closer-mop:class-precedence-list classes)
       :from-end t)))

  (defun all-interface-generics (interfaces)
    (remove-duplicates
     (loop :for class :in (all-superclasses interfaces)
       :when (typep class 'interface-class)
       :append (interface-direct-generics class))))

  (defun search-gf-options (classes gf)
    (loop :for class :in classes
      :when (typep class 'interface-class) :do
      (multiple-value-bind (options foundp)
          (gethash gf (interface-generics class))
        (when foundp
          (return (values options t))))
      :finally (return (values nil nil))))

  (defun interface-gf-options (interface gf)
    (search-gf-options (all-superclasses interface) gf))

  (defun keep-keyed-clos-options (keys options)
    (remove-if-not (memberp keys) options :key 'car))

  (defun remove-keyed-clos-options (keys options)
    (remove-if (memberp keys) options :key 'car))

  (defun find-unique-clos-option (key options)
    (let* ((found (member key options :key 'car))
           (again (member key (rest found) :key 'car)))
      (when again (error "option ~S appears more than once in ~S" key options))
      (car found)))

  (defun find-multiple-clos-options (key options)
    (remove key options :key 'car :test-not 'eq)))

(defmacro define-interface-generic (interface name lambda-list &rest options)
  (let ((generic-options
         ;;(keep-keyed-clos-options '(declare :documentation :method-combination :generic-function-class :method-class :argument-precedence-order) options)
         (remove-keyed-clos-options '(:in :out :values) options))
        (in (find-unique-clos-option :in options))
        (out (find-unique-clos-option :out options))
        (values (find-unique-clos-option :values options)))
    `(progn
       (defgeneric ,name ,lambda-list ,@generic-options)
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (register-interface-generic
          ',interface ',name
          :lambda-list ',lambda-list
          ,@(when in `(:in ',(cdr in)))
          ,@(when out `(:out ',(cdr out)))
          ,@(when values `(:values ',(cdr values))))))))

(defmacro define-interface (interface super-interfaces slots &rest options)
  (let ((class-options
         ;;(keep-keyed-clos-options '(:default-initargs :documentation :metaclass) options)
         (remove-keyed-clos-options
          '(:generic :method :singleton :parametric) options))
        (metaclass (find-unique-clos-option :metaclass options))
        (gfs (find-multiple-clos-options :generic options))
        (methods (find-multiple-clos-option :method options))
        (parametric (find-unique-clos-option :parametric options))
        (singleton (find-unique-clos-option :singleton options)))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (defclass ,interface ,super-interfaces ,slots
           ,@(unless metaclass `((:metaclass interface-class)))
           ,@class-options))
       ,@(when (or parametric singleton)
           (destructuring-bind (formals &body body)
               (or (cdr parametric)
                   '(() (make-interface)))
             `((define-memo-function
                   (,interface
                    :normalization
                    #'(lambda (make-interface &rest arguments)
                        (flet ((make-interface (&rest arguments)
                                 (apply make-interface arguments)))
                          (apply #'(lambda ,formals
                                     (block ,interface
                                       ,@body))
                                 arguments))))
                   (&rest arguments)
                 (apply 'make-instance ',interface arguments)))))
       ,@(when singleton `((defvar ,interface (,interface))))
       ,@(loop :for (() . gf) :in gfs :collect
           `(define-interface-generic ,interface ,@gf))
       ,@(when methods
           (with-gensyms (ivar)
             `((define-interface-methods (,ivar ,interface) ,@methods))))
       ',interface)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun make-local-name (name &key prefix package)
    (intern (if prefix (strcat (string prefix) (string name)) (string name))
            (or package *package*)))
  (defun collect-function-names (functions-spec)
    (remove-duplicates
     (loop :for spec :in (alexandria:ensure-list functions-spec)
       :append
       (etypecase spec
         (list spec)
         (symbol (all-interface-generics spec)))))))

(defmacro with-interface ((interface-sexp functions-spec &key prefix package) &body body)
  (with-gensyms (arguments)
    (let ((function-names (collect-function-names functions-spec)))
      `(flet ,(loop :for function-name :in function-names
                :for local-name = (make-local-name function-name :prefix prefix :package package)
                :collect
                `(,local-name (&rest ,arguments)
                              (apply ',function-name ,interface-sexp ,arguments)))
       (declare (ignorable ,@(mapcar (lambda (x) `#',x) function-names)))
       (declare (inline ,@function-names))
       ,@body))))

(defmacro define-interface-specialized-functions (interface-sexp functions-spec &key prefix package)
  (with-gensyms (arguments)
    (let ((function-names (collect-function-names functions-spec)))
      `(progn
         ,(loop :for function-name :in function-names
            :for local-name = (make-local-name function-name :prefix prefix :package package)
            :do (assert (not (eq local-name function-name)))
            :collect
            `(defun ,local-name (&rest ,arguments)
               (apply ',function-name ,interface-sexp ,arguments)))
         (declaim (inline ,@function-names))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun lambda-list-mimicker (lambda-list &optional gensym-all)
    (nest
     (multiple-value-bind (required optionals rest keys allow-other-keys aux)
         (alexandria:parse-ordinary-lambda-list lambda-list)
       (declare (ignore aux)))
     (let ((keyp (and (or keys (member '&key lambda-list)) t))
           (mappings ())))
     (labels ((g (&rest rest) (gensym (format nil "~{~A~}" rest)))
              (m (s) (if gensym-all (g s) s))
              (p (x y) (push (cons x y) mappings))))
     (let ((mrequired (loop :for rvar :in required
                        :for mrvar = (m rvar)
                        :do (p rvar mrvar)
                        :collect mrvar))
           (moptionals (loop :for (ovar #|defaults:|#() opvar) :in optionals
                         :for movar = (m ovar)
                         :for mopvar = (if opvar (m opvar) (g ovar :p))
                         :do (p ovar movar) (when opvar (p opvar mopvar))
                         :collect (list movar () mopvar)))
           (mrest (cond
                    (rest
                     (let ((mrest (m rest)))
                       (p rest mrest)
                       mrest))
                    (keyp
                     (g 'keys))))
           (mkeys (loop :for (kv def kp) :in keys
                    :for (kw kvar) = kv
                    :for mkvar = (m kvar)
                    :do (p kvar mkvar)
                    :collect `((,kw ,mkvar)))))
       (values
        ;; mimic-lambda-list
        (append mrequired
                (when moptionals (cons '&optional moptionals))
                (when mrest (list '&rest mrest))
                (when mkeys (cons '&key mkeys))
                (when allow-other-keys '(&allow-other-keys)))
        ;; mimic-ignorables
        (mapcar 'cadar mkeys)
        ;; mimic-invoker
        (if (or optionals rest) 'apply 'funcall)
        ;; mimic-arguments
        (append required
                (reduce
                 #'(lambda (moptional acc)
                     (destructuring-bind (movar default mopvar) moptional
                       (declare (ignore default))
                       `(if ,mopvar (cons ,movar ,acc) '())))
                 moptionals
                 :initial-value mrest
                 :from-end t))
        (reverse mappings))))))

(defmacro define-interface-method (interface gf &rest rest)
  (multiple-value-bind (interface-var interface-class)
      (etypecase interface
        (cons (values (first interface) (second interface)))
        (symbol (values interface interface)))
    (finalize-inheritance (find-class interface-class))
    (if (length=n-p rest 1)
        ;; One-argument: simply map a method to an interface-less function
        (nest
         (let ((lambda-list (closer-mop:generic-function-lambda-list gf))
               (function (first rest))))
         (multiple-value-bind (mimic-lambda-list
                               mimic-ignorables
                               mimic-invoker mimic-arguments #|mappings|#)
             (lambda-list-mimicker lambda-list))
         (let ((i-var (first mimic-lambda-list))))
         `(defmethod ,gf ((,i-var ,interface-class) ,@(rest mimic-lambda-list))
            (declare (ignorable ,i-var ,@mimic-ignorables))
            (,mimic-invoker ,function ,@(rest mimic-arguments))))
        ;; More than one argument: a method that uses current interface
        (nest
         (destructuring-bind (lambda-list &rest body) rest)
         (multiple-value-bind (remaining-forms declarations doc-string)
             (alexandria:parse-body body :documentation t))
         `(defmethod ,gf ((,interface-var ,interface-class) ,@lambda-list)
            ,@doc-string ,@declarations (declare (ignorable ,interface-var))
            (with-interface (,interface-var ,interface-class)
              ,@remaining-forms))))))

(defmacro define-interface-methods (interface &body body)
  `(macrolet ((:method (gf &rest rest)
                `(define-interface-method ,',interface ,gf ,@rest)))
     ,@body))

(define-interface <interface> ()
  ()
  (:documentation "An interface, encapsulating an algorithm"))
