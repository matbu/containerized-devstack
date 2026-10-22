# Thin wrapper around run.sh. Override anything from config.env on the CLI, e.g.
#   make all LAB_HOST=root@otherbox DEVSTACK_BRANCH=stable/2025.2
.PHONY: all sync prep build up stack route push info shell logs destroy nuke

all:     ; ./run.sh all
sync:    ; ./run.sh sync
prep:    ; ./run.sh prep
build:   ; ./run.sh build
up:      ; ./run.sh up
stack:   ; ./run.sh stack
route:   ; ./run.sh route
push:    ; ./run.sh push
info:    ; ./run.sh info
shell:   ; ./run.sh shell
logs:    ; ./run.sh logs
destroy: ; ./run.sh destroy
nuke:    ; ./run.sh nuke
