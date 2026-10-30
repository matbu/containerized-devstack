    # pds-ovn-wait (injected by containerized-devstack): on a loaded host, neutron-api
    # can start before OVN's NB/SB are ready; its ML2/OVN driver then fails to sync
    # the geneve segmentation pool and register in the hash ring, and does NOT
    # retry until restarted. That makes the initial network creation below fail
    # with "No project network is available for allocation" / "HashRingIsEmpty".
    # Restart the neutron server against a ready OVN and wait until it has synced.
    # The neutron server unit is 'neutron-api' (newer devstack) or 'q-svc' (Epoxy).
    # OVN may not be ready on the first restart, so re-restart periodically until
    # the pool syncs (idempotent).
    for _pds_i in $(seq 1 60); do
        _pds_g=$(mysql -uroot -p"$DATABASE_PASSWORD" -N -e "SELECT COUNT(*) FROM neutron.ml2_geneve_allocations;" 2>/dev/null || echo 0)
        _pds_r=$(mysql -uroot -p"$DATABASE_PASSWORD" -N -e "SELECT COUNT(*) FROM neutron.ovn_hash_ring WHERE TIMESTAMPDIFF(SECOND,updated_at,NOW())<30;" 2>/dev/null || echo 0)
        if [ "${_pds_g:-0}" -gt 0 ] && [ "${_pds_r:-0}" -gt 0 ]; then
            echo "pds-ovn-wait: OVN ready (geneve=${_pds_g} hash_ring=${_pds_r})"
            break
        fi
        if [ "$(( (_pds_i - 1) % 8 ))" -eq 0 ]; then   # re-restart every ~24s
            sudo systemctl restart devstack@neutron-api 2>/dev/null || true
            sudo systemctl restart devstack@q-svc 2>/dev/null || true
        fi
        sleep 3
    done
