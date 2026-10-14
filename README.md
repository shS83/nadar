# NADAR v0.4

Värillinen TCP/UDP-kuuntelijoiden tarkastin ja systemd-käyttäjäpalveluna toimiva paikallinen porttivahti. Perustuu aiempaan NetRadar v0.1 -versioon.

## Asennus Arch Linuxiin

```bash
sudo pacman -S --needed iproute2 libnotify xdg-utils
install -Dm755 nadar ~/.local/bin/nadar
install -Dm644 nadar.service ~/.config/systemd/user/nadar.service
# Säilytä olemassa olevat omat asetuksesi:
if [[ ! -f ~/.config/nadar/nadar.conf ]]; then
  install -Dm644 nadar.conf ~/.config/nadar/nadar.conf
fi
systemctl --user daemon-reload
systemctl --user enable --now nadar.service
```

Jos olet jo nimennyt vanhan NetRadar-asennuksesi `nadar`-nimiseksi, riittää yleensä skriptin korvaaminen. Käyttäjäpalvelu kannattaa käynnistää uudelleen vain jos `--watch`-toimintoa on muutettu tai haluat varmasti käyttöön uuden version:

```bash
systemctl --user restart nadar.service
```

## Komennot

```bash
nadar --list             # yksi ss:n soketti per rivi, myös päällekkäiset
nadar --summary          # sama protocol + address + port yhdistettynä
nadar --summary-html     # luo ./summary.html ja avaa sen xdg-openilla
nadar --watch            # jatkuva paikallinen valvonta
nadar --once             # päivitä tallennettu tila ja ilmoita uusista
nadar --status           # käyttäjäpalvelun tila
nadar --reset            # nollaa lähtötilanne
```

Oletuksena `nadar` näyttää `--list`-näkymän. `NADAR_INTERVAL=10` määrittää `--watch`-tilan tarkistusvälin sekunteina. `NADAR_HTML_PATH=/polku/raportti.html` määrittää HTML-tulosteen kohteen. HTML on itsenäinen ja sisältää vain paikalliset havainnot.

Huomaa, että `ss -p` voi jättää muiden käyttäjien tai rootin prosessinimet ja PID:t näyttämättä. Näkymä ei tarkoita, että portit olisivat saavutettavissa internetistä. Ulkoinen Nmap on erillinen tuleva ominaisuus.

## Asetukset

Asennuspaketissa on `nadar.conf`, joka sijoitetaan polkuun
`~/.config/nadar/nadar.conf`. Jos tiedostoa ei ole, oletukset ovat
`LISTENPROTO="TCP,UDP"`, `EXCLUDEPORTS=""`, `EXCLUDE_PROCESSES=""`, `EXCLUDE_PIDS=""` ja `NADAR_INTERVAL=10`.

```bash
LISTENPROTO="TCP,UDP"      # TCP, UDP tai TCP,UDP
EXCLUDEPORTS=""                # halutessasi esim. UDP:1900
EXCLUDE_PROCESSES="spotify,firefox"
EXCLUDE_PIDS="1567,1447"
NADAR_INTERVAL=10
```

`EXCLUDEPORTS` hyväksyy myös numerot ilman protokollaa (`445,5353`),
jolloin sekä TCP että UDP jätetään pois. Porttialueissa käytetään
merkintää `10000-11000`, tai `UDP:10000-11000`.

`EXCLUDE_PROCESSES` suodattaa `ss -p` -tulosteen prosessinimen perusteella
(täsmällinen nimi, kirjainkoolla ei ole väliä); esimerkiksi `spotify` jättää
kaikki Spotify-prosessit pois riippumatta niiden PID:stä. `EXCLUDE_PIDS`
suodattaa täsmällisten PID-lukujen perusteella. Nämä ovat vaihtoehtoisia:
jos nimi **tai** PID vastaa, kyseinen prosessi ohitetaan.

Jos samalle socketille näkyy useita omistajia, vain suodatetut omistajat
poistetaan; jäljelle jäävä prosessi näkyy raporteissa. Jos `ss -p` ei näytä
prosessitietoja käyttöoikeuksien vuoksi, NADAR **ei suodata** kyseistä
socketia prosessin perusteella (turvallinen oletus). PID voi vaihtua
uudelleenkäynnistyksessä, joten jatkuvaan suodatukseen kannattaa käyttää
prosessinimeä. Suodatus toimii sekä näkymissä että daemonin hälytyksissä.

Asetustiedostoa ei suoriteta Bash-koodina. Rivillä saa olla yksi asetus,
ja kommentit aloitetaan omalta riviltä merkillä `#`.

Kaikki näkymät ja daemon käyttävät samaa suodatusta. Kun asetuksia muuttaa,
käynnistä käyttäjäpalvelu uudelleen:

```bash
systemctl --user daemon-reload
systemctl --user restart nadar.service
```

Vanhan valvontatilanteen voi tarvittaessa nollata komennolla
`nadar --reset` ennen palvelun uudelleenkäynnistystä. Tällöin ensimmäinen
tarkistus muodostaa uuden lähtötilanteen ilman hälytyksiä.

Huomio: Suodatetut portit eivät näy raporteissa **eivätkä aiheuta hälytyksiä**.
`LISTENPROTO="TCP"` on sopiva vaihtoehto, jos lyhytikäiset UDP-soketit
aiheuttavat liikaa ilmoituksia.

## Varoitus prosessisuodatuksesta

Prosessinimen perusteella tehty suodatus on käyttömukavuustoiminto, ei
tietoturvaraja. Sovellus voi käyttää eri prosessinimeä, ja puuttuvat
prosessitiedot näkyvät edelleen. NADARin hälytykset kertovat paikallisista
kuuntelupisteistä, eivät suoraan internetiin avatuista porteista.
