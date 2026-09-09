# Todo

## Akut
 
 - Komplette FPGA Generic Konfiguration am Control Plane Interface Exposen
 - 100 Mbit Eth auf Gigabit Phy fixen
 - Paketfilter für MCU strenger gestalten
 - Build System
   - Build auf Gowin
   - Build auf Lattice
   - Maybe über LiteX Builder? 
- ESP32 PSRAM Zephyr fixen
- DOKU AKTUALISIEREN!!!!!

---

## Geplant

  - Repo Aufräumen
  - Dumme Claude kommentare entfernen
  - TDM Mux/Demux direkt in die Audio RX/TX Pfade integrieren (einfach in echtzeit aus dem RAM rausshiften): Spart einen haufen Ressourcen und 1 Sample Latenz
  - weitere samplerates
  - Gowin weiter debuggen - irgendwo macht die Gowin EDA den Ethernet Clock tree kaputt
---

## Nice to have

  - Linux Binary zur Konfiguration per SPI
  - Option: Sample Buffer auf externen RAM

## PCIe Karte (Alibaba AS02MC04 / XCKU3P)

  - Erster Vivado-Build: Portlisten der xdma_0 / gig_eth_pcs_pma_0 Components gegen die generierten IP-Templates prüfen
  - PCIe Link-Training (Lane Reversal, PERST A9 vs T19) und PCS/PMA-Link am SFP testen
  - Audio-DMA-Engine mit aplay/arecord verifizieren (Pointer/Period-IRQs, Under-/Overrun-Zähler)
