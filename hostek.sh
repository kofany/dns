#!/bin/bash

# Token Cloudflare
TOKEN=""
AUTHORIZED_PASSWORD=""

show_instruction() {
    # Definicje kolorów
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # Brak koloru

    echo -e "${YELLOW}Instrukcja użytkowania skryptu hostek:${NC}"
    echo -e "$0  ${GREEN}dodaj ptr [IPv6] [host]${NC} - Dodaje rekord PTR dla adresu IPv6 i hosta"
    echo -e "$0  ${GREEN}dodaj a [IPv4] [host]${NC}   - Dodaje rekord A dla adresu IPv4 i hosta"
    echo -e "$0  ${GREEN}dodaj aaaa [IPv6] [host]${NC} - Dodaje rekord AAAA dla adresu IPv6 i hosta"
    echo -e "$0  ${RED}usun ptr [IPv6]${NC}          - Usuwa rekord PTR dla adresu IPv6"
    echo -e "$0  ${RED}usun a [IPv4] [host]${NC}     - Usuwa rekord A dla adresu IPv4 i hosta"
    echo -e "$0  ${RED}usun aaaa [IPv6] [host]${NC}  - Usuwa rekord AAAA dla adresu IPv6 i hosta"
    echo -e "$0  ${YELLOW}pokaz domeny${NC}             - Wyświetla listę stref"
    echo -e "$0  ${YELLOW}pokaz wpisy [strefa]${NC}     - Wyświetla rekordy dla danej strefy"
}
dns_operation() {
    local operation=$1
    local record_type=$2
    local ip_address=$3
    local domain=$4
    local target=$2
    local target_zone=$3

    case "$operation" in
        "dodaj")
            case "$record_type" in
                "ptr")
                    add_ptr "$ip_address" "$domain"
                    ;;
                "a")
                    add_a "$ip_address" "$domain"
                    ;;
                "aaaa")
                    add_aaaa "$ip_address" "$domain"
                    ;;
                *)
                    echo "Nieznany typ rekordu: $record_type"
                    return 1
                    ;;
            esac
            ;;
        "pokaz")
            case "$target" in
                "domeny")
                    show_zones
                    ;;
                "wpisy")
                    show_records "$target_zone"
                    ;;
                *)
                    echo "Nieznane zapytanie: $record_type"
                    return 1
                    ;;
            esac
            ;;
        "usun")
            case "$record_type" in
                "ptr")
                    del_ptr6 "$ip_address"
                    ;;
                "a")
                    del_a "$ip_address" "$domain"
                    ;;
                "aaaa")
                    del_aaaa "$ip_address" "$domain"
                    ;;
                *)
                    echo "Nieznany typ rekordu: $record_type"
                    return 1
                    ;;
            esac
            ;;
        *)
            show_instruction
            return 1
            ;;
    esac
}
check_record_existence() {
    local host=$1
    local zone_id=$2
    local record_type=$3

    local records_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type&name=$host" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    local record_exists=$(echo "$records_response" | jq -r '.result[] | select(.name == "'$host'") | .id')

    if [ -n "$record_exists" ]; then
        echo "Rekord $record_type dla hosta $host już istnieje. Wymagana autoryzacja do dodania zduplikowanego rekordu."
        read -sp "Podaj hasło: " password
        echo

        if [ "$password" == "$AUTHORIZED_PASSWORD" ]; then
            echo "Autoryzacja udana. Kontynuowanie dodawania rekordu."
            return 0
        else
            echo "Nieprawidłowe hasło. Nie można dodać zduplikowanego rekordu."
            exit 1
        fi
    fi

    return 0
}
convert_ipv6_to_arpa() {
    local ipv6_address=$1
    local full_ipv6=$(echo $ipv6_address | awk -F: 'BEGIN {OFS=""; } {addCount = 9 - NF; for(i=1; i<=NF; i++){if(length($i) == 0) {for(j=1; j<=addCount; j++) { $i = ($i "0000"); } } else { $i = substr(("0000" $i), length($i) + 5 - 4); }}; print}')
    local reversed_ipv6=$(echo $full_ipv6 | sed 's/://g;s/^.*$/\n&\n/;tx;:x;s/\(\n.\)\(.*\)\(.\n\)/\3\2\1/;tx;s/\n//g;s/\(.\)/\1./g;s/$/ip6.arpa/')
    echo "$reversed_ipv6"
}
# Funkcja do wyszukiwania pasującej strefy ip6.arpa
find_matching_zone() {
    local arpa_address=$1
    local zones
    local found_zone_id=""

    # Pobieranie wszystkich stref
    local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    zones=$(echo "$zones_response" | jq -c '.result[] | {id, name}')

    # Szukanie pasującej strefy
    for row in $(echo "${zones}" | jq -r '. | @base64'); do
        _jq() {
            echo ${row} | base64 --decode | jq -r ${1}
        }

        local zone_id=$(_jq '.id')
        local zone_name=$(_jq '.name')

        if [[ "$arpa_address" == *"$zone_name"* ]]; then
            found_zone_id=$zone_id
            break
        fi
    done

    if [ -z "$found_zone_id" ]; then
        return 1
    else
        echo $found_zone_id
        return 0
    fi
}
####################################################
add_ptr() {

add_ptr_record() {
    local ipv6_address=$1
    local domain_name=$2
    local arpa_address=$(convert_ipv6_to_arpa $ipv6_address)

    # Wyszukiwanie pasującej strefy
    local zone_id=$(find_matching_zone $arpa_address)

    if [ -z "$zone_id" ]; then
        echo "Nie znaleziono odpowiedniej strefy dla adresu ARPA: $arpa_address"
        return 1
    fi

    local data="{\"type\":\"PTR\",\"name\":\"$arpa_address\",\"content\":\"$domain_name\",\"ttl\":120}"
    local post_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$data")

    # Sprawdzenie, czy dodanie rekordu zakończyło się sukcesem
    local success=$(echo "$post_response" | jq -r '.success')
    local error_message=$(echo "$post_response" | jq -r '.errors[]?.message')

    if [[ "$success" == "true" ]]; then
        echo "Rekord PTR został pomyślnie dodany."
    else
        echo "Błąd przy dodawaniu rekordu PTR: $error_message"
    fi
}

# Wywołanie funkcji z argumentami przekazanymi z linii poleceń
add_ptr_record "$1" "$2"
}

del_ptr6() {
    local ipv6_address=$1
    local arpa_address=$(convert_ipv6_to_arpa $ipv6_address)

    echo "Adres ARPA: $arpa_address"

    local zone_id=$(find_matching_zone $arpa_address)

    if [ -z "$zone_id" ]; then
        echo "Nie znaleziono odpowiedniej strefy dla adresu ARPA: $arpa_address"
        return 1
    fi

    echo "ID znalezionej strefy: $zone_id"

    # Pobieranie i wyświetlanie wszystkich rekordów DNS w strefie
    local all_records_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    # Szukanie konkretnego rekordu PTR
    local record_id=$(echo "$all_records_response" | jq -r '.result[] | select(.type == "PTR" and .name == "'$arpa_address'") | .id')

    if [ -z "$record_id" ]; then
        echo "Nie znaleziono rekordu PTR dla adresu: $ipv6_address"
        return 1
    fi

    echo "ID rekordu PTR do usunięcia: $record_id"

    # Usuwanie rekordu PTR
    local delete_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    local success=$(echo "$delete_response" | jq -r '.success')

    if [[ "$success" == "true" ]]; then
        echo "Rekord PTR został pomyślnie usunięty."
    else
        local error_message=$(echo "$delete_response" | jq -r '.errors[]?.message')
        echo "Błąd przy usuwaniu rekordu PTR: $error_message"
    fi
}

add_a() {
    local ip_address=$1
    local host=$2

    # Pobieranie listy stref
    local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")
    local zones=$(echo "$zones_response" | jq -r '.result[] | .name')

    # Szukanie pasującej strefy
    local zone=""
    for z in $zones; do
        if [[ "$host" == *"$z" ]]; then
            zone=$z
            break
        fi
    done

    if [ -z "$zone" ]; then
        echo "Nie znaleziono strefy dla hosta: $host"
        return 1
    fi

    local zone_id=$(echo "$zones_response" | jq -r --arg zone_name "$zone" '.result[] | select(.name == $zone_name) | .id')

    echo "Znaleziono strefę: $zone (ID: $zone_id)"
    # Sprawdzanie, czy rekord już istnieje
    check_record_existence "$host" "$zone_id" "A"
    # Dodawanie rekordu A
    local data="{\"type\":\"A\",\"name\":\"$host\",\"content\":\"$ip_address\",\"ttl\":1,\"proxied\":false}"
    local post_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$data")

    local success=$(echo "$post_response" | jq -r '.success')

    if [[ "$success" == "true" ]]; then
        echo "Rekord A został pomyślnie dodany dla $host."
    else
        local error_message=$(echo "$post_response" | jq -r '.errors[]?.message')
        echo "Błąd przy dodawaniu rekordu A dla $host: $error_message"
    fi
}

del_a() {
    local ip_address=$1
    local host=$2

    # Pobieranie listy stref
    local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")
    local zones=$(echo "$zones_response" | jq -r '.result[] | .name')

    # Szukanie pasującej strefy
    local zone=""
    for z in $zones; do
        if [[ "$host" == *"$z" ]]; then
            zone=$z
            break
        fi
    done

    if [ -z "$zone" ]; then
        echo "Nie znaleziono strefy dla hosta: $host"
        return 1
    fi

    local zone_id=$(echo "$zones_response" | jq -r --arg zone_name "$zone" '.result[] | select(.name == $zone_name) | .id')
    echo "Znaleziono strefę: $zone (ID: $zone_id)"

    # Pobieranie rekordów A dla strefy
    local records_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$host" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    # Szukanie i usuwanie pasujących rekordów A
    local records=$(echo "$records_response" | jq -r '.result[] | select(.content == "'$ip_address'") | .id')
    local record_found=false

    for record_id in $records; do
        if [ -n "$record_id" ]; then
            record_found=true
            echo "Usuwanie rekordu A (ID: $record_id) dla $host z adresem IP $ip_address"
            local delete_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json")

            local success=$(echo "$delete_response" | jq -r '.success')
            if [[ "$success" == "true" ]]; then
                echo "Rekord A (ID: $record_id) został pomyślnie usunięty."
            else
                local error_message=$(echo "$delete_response" | jq -r '.errors[]?.message')
                echo "Błąd przy usuwaniu rekordu A (ID: $record_id): $error_message"
            fi
        fi
    done

    if [ "$record_found" = false ]; then
        echo "Nie znaleziono rekordu A dla $host z adresem IP $ip_address"
    fi
}
add_aaaa() {
    local ipv6_address=$1
    local host=$2

    # Pobieranie listy stref
    local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")
    local zones=$(echo "$zones_response" | jq -r '.result[] | .name')

    # Szukanie pasującej strefy
    local zone=""
    for z in $zones; do
        if [[ "$host" == *"$z" ]]; then
            zone=$z
            break
        fi
    done

    if [ -z "$zone" ]; then
        echo "Nie znaleziono strefy dla hosta: $host"
        return 1
    fi

    local zone_id=$(echo "$zones_response" | jq -r --arg zone_name "$zone" '.result[] | select(.name == $zone_name) | .id')

    echo "Znaleziono strefę: $zone (ID: $zone_id)"
    # Sprawdzanie, czy rekord już istnieje
    check_record_existence "$host" "$zone_id" "AAAA"
    # Dodawanie rekordu AAAA
    local data="{\"type\":\"AAAA\",\"name\":\"$host\",\"content\":\"$ipv6_address\",\"ttl\":1,\"proxied\":false}"
    local post_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$data")

    local success=$(echo "$post_response" | jq -r '.success')

    if [[ "$success" == "true" ]]; then
        echo "Rekord AAAA został pomyślnie dodany dla $host."
    else
        local error_message=$(echo "$post_response" | jq -r '.errors[]?.message')
        echo "Błąd przy dodawaniu rekordu AAAA dla $host: $error_message"
    fi
}
del_aaaa() {
    local ipv6_address=$1
    local host=$2

    # Pobieranie listy stref
    local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")
    local zones=$(echo "$zones_response" | jq -r '.result[] | .name')

    # Szukanie pasującej strefy
    local zone=""
    for z in $zones; do
        if [[ "$host" == *"$z" ]]; then
            zone=$z
            break
        fi
    done

    if [ -z "$zone" ]; then
        echo "Nie znaleziono strefy dla hosta: $host"
        return 1
    fi

    local zone_id=$(echo "$zones_response" | jq -r --arg zone_name "$zone" '.result[] | select(.name == $zone_name) | .id')
    echo "Znaleziono strefę: $zone (ID: $zone_id)"

    # Pobieranie rekordów AAAA dla strefy
    local records_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=AAAA&name=$host" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    # Szukanie i usuwanie pasujących rekordów AAAA
    local records=$(echo "$records_response" | jq -r '.result[] | select(.content == "'$ipv6_address'") | .id')
    local record_found=false

    for record_id in $records; do
        if [ -n "$record_id" ]; then
            record_found=true
            echo "Usuwanie rekordu AAAA (ID: $record_id) dla $host z adresem IPv6 $ipv6_address"
            local delete_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json")

            local success=$(echo "$delete_response" | jq -r '.success')
            if [[ "$success" == "true" ]]; then
                echo "Rekord AAAA (ID: $record_id) został pomyślnie usunięty."
            else
                local error_message=$(echo "$delete_response" | jq -r '.errors[]?.message')
                echo "Błąd przy usuwaniu rekordu AAAA (ID: $record_id): $error_message"
            fi
        fi
    done

    if [ "$record_found" = false ]; then
        echo "Nie znaleziono rekordu AAAA dla $host z adresem IPv6 $ipv6_address"
    fi
}
show_zones() {
    # Pobieranie listy stref
    local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    # Oddzielanie stref .arpa od reszty
    local arpa_zones=$(echo "$zones_response" | jq -r '.result[] | select(.name | endswith(".arpa")) | .name')
    local non_arpa_zones=$(echo "$zones_response" | jq -r '.result[] | select(.name | endswith(".arpa") | not) | .name')

    # Wyświetlanie stref innych niż .arpa w trzech kolumnach
    echo "Strefy domen:"
    echo "$non_arpa_zones" | awk '{
        printf "%-30s", $0
        if (NR % 3 == 0)
            print ""
    }'
    echo # Drukuj nową linię

    # Wyświetlanie stref .arpa w jednej kolumnie
    echo "Strefy .arpa:"
    echo "$arpa_zones"
}
show_records() {
    local zone_name=$1

    # Pobieranie ID strefy
    local zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$zone_id" ] || [ "$zone_id" == "null" ]; then
        echo "Nie znaleziono strefy: $zone_name"
        return 1
    fi

    # Pobieranie rekordów DNS dla strefy
    local records_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")

    echo "Rekordy dla strefy $zone_name:"
    echo "$records_response" | jq -r '.result[] | "\(.type) \(.content) \(.name)"' | \
    awk '{printf "%-4s %-40s %-30s\n", $1, $2, $3}'
}


dns_operation "$1" "$2" "$3" "$4"
