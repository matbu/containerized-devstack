    # pds-ovn-wait (injected by containerized-devstack): on a loaded host, neutron-api
    # can start before OVN's NB/SB are ready; its ML2/OVN driver then fails to sync
    # the geneve segmentation pool and register in the hash ring, and does NOT
    # retry until restarted. That makes the initial network creation below fail
    # with "No project network is available for allocation" / "HashRingIsEmpty".
    # Restart neutron-api against a now-ready OVN and wait until it has synced.
    sudo systemctl restart devstack@neutron-api 2>/dev/null || true
    for _pds_i in $(seq 1 60); do
        _pds_g=$(mysql -uroot -p"$DATABASE_PASSWORD" -N -e "SELECT COUNT(*) FROM neutron.ml2_geneve_allocations;" 2>/dev/null || echo 0)
        _pds_r=$(mysql -uroot -p"$DATABASE_PASSWORD" -N -e "SELECT COUNT(*) FROM neutron.ovn_hash_ring WHERE TIMESTAMPDIFF(SECOND,updated_at,NOW())<30;" 2>/dev/null || echo 0)
        if [ "${_pds_g:-0}" -gt 0 ] && [ "${_pds_r:-0}" -gt 0 ]; then
            echo "pds-ovn-wait: OVN ready (geneve=${_pds_g} hash_ring=${_pds_r})"
            break
        fi
        sleep 2
    done
