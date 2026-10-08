# Kestrel Weather Station

Kestrel is a small open-source firmware for solar-powered weather stations.
It reads temperature, humidity, pressure and wind speed, stores the samples
on a flash chip and sends a compact report over LoRa every ten minutes.
The firmware fits in **96 KB of flash** and sleeps between readings, so one
18650 cell lasts through a cloudy week.

## Features

- Reads up to six sensors on one I²C bus
- Stores 30 days of samples in a ring buffer on SPI flash
- Sends reports over LoRa or prints them on the serial port
- Wakes on a timer or on a rain-gauge pulse
- Calibrates each sensor with a two-point offset table

### Supported sensors

| Sensor   | Measures                  | Bus  | Accuracy     |
|----------|---------------------------|------|--------------|
| BME280   | temperature, humidity, pressure | I²C | ±0.5 °C, ±3 % |
| SHT31    | temperature, humidity     | I²C  | ±0.3 °C, ±2 % |
| AS5600   | wind direction            | I²C  | ±1°          |
| Reed cup | wind speed                | GPIO | ±0.5 m/s     |
| Tipping bucket | rainfall            | GPIO | 0.2 mm/tip   |

### Power budget

The station spends most of its life asleep. One measurement cycle takes
about 180 ms at 12 mA. Sleep current is 9 µA. With a 2 W panel, the
battery stays above 80 % from March to October.

## Getting started

### Hardware

You need a board with an RP2040 or an nRF52840, a LoRa module, and at least
one sensor from the table above. The `boards/` folder has pin maps for four
common boards.

### Build and flash

Install the toolchain, then build for your board:

```sh
git clone https://example.com/kestrel/kestrel.git
cd kestrel
make BOARD=pico-lora
make flash PORT=/dev/ttyACM0
```

The first boot prints the station ID and the sensor list on the serial
port at 115200 baud.

### Configuration

Edit `config/station.toml` before you flash. The most common keys:

```toml
[station]
name = "hilltop-02"
interval_s = 600

[radio]
band = "eu868"
spreading_factor = 9
```

## Data format

Each report is 24 bytes. Fields are little-endian. Temperature is stored in
centidegrees as `int16`, pressure in pascals minus 50 000 as `uint16`.

> Keep the report under 32 bytes. Longer packets at spreading factor 9
> exceed the duty-cycle limit in some regions, and the gateway drops them
> without a warning.

## Roadmap

- [x] Ring buffer on SPI flash
- [x] Two-point sensor calibration
- [x] Rain-gauge wake-up
- [ ] Config updates over LoRa
- [ ] Solar charge reporting
- [ ] Web dashboard for the gateway

## Полевые испытания

Прошлой осенью мы поставили три станции на холме у реки и оставили их
на шесть недель без присмотра. Две станции проработали весь срок без
перезагрузок. Третья замолчала на девятый день: в корпус попала вода,
и датчик влажности показывал сто процентов даже в солнечный полдень.

После этого мы добавили в корпус мембранный клапан и перенесли плату
выше разъёма. Новая версия корпуса пережила две грозы и первый снег.
Батарея ни разу не опустилась ниже шестидесяти процентов.

### Что мы узнали

- Дешёвые датчики ветра быстро изнашиваются, их надо менять раз в год.
- Отчёт раз в десять минут — разумный баланс между точностью и батареей.
- Метка времени должна приходить от шлюза, а не от часов станции.

## Contributing

Bug reports and pull requests are welcome. Read the
[contributor guide](https://example.com) first, run `make test` before you
open a pull request, and keep each change small. New board support needs a
pin map and one photo of a working station.

## License

Kestrel is released under the MIT license.
