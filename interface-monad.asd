
(asdf:defsystem :interface-monad
  :description
  "The <monad> done interface passing style"
  :depends-on
  (:interface/monad))

(asdf:defsystem :interface/monad
  :depends-on
  (:interface)
  :components
  ((:module "interface" :components ((:file "monad")))))

(asdf:defsystem :interface/monad/identity
  :depends-on
  (:interface/monad)
  :components
  ((:module "interface" :components
    ((:module "monad" :components ((:file "identity")))))))
