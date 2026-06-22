#include <Arduino.h>
#include <driver/pcnt.h>
#include <NimBLEDevice.h>

// -------------------- Pins --------------------

constexpr int FAN1_PWM_PIN  = 23;
constexpr int FAN2_PWM_PIN  = 22;

constexpr int FAN1_TACH_PIN = 19;
constexpr int FAN2_TACH_PIN = 18;

constexpr int FAN1_POT_PIN  = 32; // ADC1_CH4
constexpr int FAN2_POT_PIN  = 33; // ADC1_CH5

// -------------------- Fan/PWM settings --------------------

// 4-Pin-PC-Lüfter: typischer PWM-Wert ca. 25 kHz
constexpr uint32_t PWM_FREQ_HZ = 25000;
constexpr uint8_t  PWM_RES_BITS = 8;   // 0..255

// Arduino-ESP32 2.x nutzt LEDC-Kanäle, 3.x arbeitet direkt mit Pins.
constexpr uint8_t FAN1_PWM_CHANNEL = 0;
constexpr uint8_t FAN2_PWM_CHANNEL = 1;

constexpr uint8_t DUTY_MIN_PERCENT = 20;   // unterhalb laufen manche Lüfter unsicher
constexpr uint8_t DUTY_MAX_PERCENT = 100;

// Achtung: mit BJT/Open-Collector ist das Signal invertiert.
// ESP32 HIGH -> BJT leitet -> PWM-Pin des Lüfters LOW.
// Daher invertieren wir die Duty-Ausgabe.
constexpr bool PWM_INVERTED_BY_BJT = true;

// Tacho: PC-Lüfter meist 2 Pulse pro Umdrehung
constexpr uint8_t TACH_PULSES_PER_REV = 2;
constexpr pcnt_unit_t FAN1_TACH_PCNT_UNIT = PCNT_UNIT_0;
constexpr pcnt_unit_t FAN2_TACH_PCNT_UNIT = PCNT_UNIT_1;
constexpr uint16_t TACH_PCNT_FILTER_CYCLES = 1000; // 12.5 us bei 80 MHz APB

// -------------------- State --------------------

uint16_t fan1Rpm = 0;
uint16_t fan2Rpm = 0;

uint8_t fan1DutyPercent = 0;
uint8_t fan2DutyPercent = 0;

bool autoMode = true;

// Für getrennte Regelung kannst du später z.B. fan2 etwas schneller laufen lassen:
int8_t fan1OffsetPercent = 0;
int8_t fan2OffsetPercent = 0;

// BLE
constexpr const char* BLE_DEVICE_NAME = "SolderFan";
NimBLECharacteristic* statusCharacteristic = nullptr;

// -------------------- Helpers --------------------

uint8_t clampPercent(int value) {
  if (value < 0) return 0;
  if (value > 100) return 100;
  return static_cast<uint8_t>(value);
}

uint8_t percentToDutyRaw(uint8_t percent) {
  const uint16_t maxDuty = (1 << PWM_RES_BITS) - 1; // 255 bei 8 Bit
  uint16_t duty = (percent * maxDuty) / 100;

  if (PWM_INVERTED_BY_BJT) {
    duty = maxDuty - duty;
  }

  return static_cast<uint8_t>(duty);
}

void setupFanPwm(uint8_t pin, uint8_t channel) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  (void)channel;
  ledcAttach(pin, PWM_FREQ_HZ, PWM_RES_BITS);
#else
  ledcSetup(channel, PWM_FREQ_HZ, PWM_RES_BITS);
  ledcAttachPin(pin, channel);
#endif
}

void writeFanPwmRaw(uint8_t pin, uint8_t channel, uint8_t duty) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  (void)channel;
  ledcWrite(pin, duty);
#else
  (void)pin;
  ledcWrite(channel, duty);
#endif
}

void setFanDutyPercent(uint8_t fan, uint8_t percent) {
  percent = clampPercent(percent);

  uint8_t raw = percentToDutyRaw(percent);

  if (fan == 1) {
    fan1DutyPercent = percent;
    writeFanPwmRaw(FAN1_PWM_PIN, FAN1_PWM_CHANNEL, raw);
  } else {
    fan2DutyPercent = percent;
    writeFanPwmRaw(FAN2_PWM_PIN, FAN2_PWM_CHANNEL, raw);
  }
}

uint8_t readPotPercentSmoothed(uint8_t fan, int potPin) {
  static uint16_t fan1Smooth = 0;
  static uint16_t fan2Smooth = 0;
  uint16_t& smooth = (fan == 1) ? fan1Smooth : fan2Smooth;

  uint16_t raw = analogRead(potPin); // 0..4095 typ.
  smooth = (smooth * 7 + raw) / 8;

  return map(smooth, 0, 4095, DUTY_MIN_PERCENT, DUTY_MAX_PERCENT);
}

void logPcntError(const char* action, esp_err_t result) {
  if (result == ESP_OK) return;

  Serial.print("PCNT ");
  Serial.print(action);
  Serial.print(" failed: ");
  Serial.println(esp_err_to_name(result));
}

void setupTachCounter(int pin, pcnt_unit_t unit) {
  pinMode(pin, INPUT_PULLUP);

  pcnt_config_t config = {};
  config.pulse_gpio_num = pin;
  config.ctrl_gpio_num = PCNT_PIN_NOT_USED;
  config.lctrl_mode = PCNT_MODE_KEEP;
  config.hctrl_mode = PCNT_MODE_KEEP;
  config.pos_mode = PCNT_COUNT_DIS;
  config.neg_mode = PCNT_COUNT_INC;
  config.counter_h_lim = 32767;
  config.counter_l_lim = 0;
  config.unit = unit;
  config.channel = PCNT_CHANNEL_0;

  logPcntError("unit_config", pcnt_unit_config(&config));
  logPcntError("set_filter", pcnt_set_filter_value(unit, TACH_PCNT_FILTER_CYCLES));
  logPcntError("filter_enable", pcnt_filter_enable(unit));
  logPcntError("pause", pcnt_counter_pause(unit));
  logPcntError("clear", pcnt_counter_clear(unit));
  logPcntError("resume", pcnt_counter_resume(unit));
}

uint32_t readAndClearTachCounter(pcnt_unit_t unit) {
  int16_t count = 0;

  pcnt_counter_pause(unit);
  pcnt_get_counter_value(unit, &count);
  pcnt_counter_clear(unit);
  pcnt_counter_resume(unit);

  return count > 0 ? static_cast<uint32_t>(count) : 0;
}

uint16_t pulsesToRpm(uint32_t pulses, uint32_t elapsedMs) {
  if (elapsedMs == 0) return 0;

  uint32_t rpm = (static_cast<uint64_t>(pulses) * 60000ULL) / (TACH_PULSES_PER_REV * elapsedMs);
  if (rpm > UINT16_MAX) return UINT16_MAX;
  return static_cast<uint16_t>(rpm);
}

void updateRpmEverySecond() {
  static uint32_t lastMs = 0;

  uint32_t now = millis();
  uint32_t elapsedMs = now - lastMs;
  if (elapsedMs < 1000) return;

  uint32_t p1 = readAndClearTachCounter(FAN1_TACH_PCNT_UNIT);
  uint32_t p2 = readAndClearTachCounter(FAN2_TACH_PCNT_UNIT);

  fan1Rpm = pulsesToRpm(p1, elapsedMs);
  fan2Rpm = pulsesToRpm(p2, elapsedMs);

  lastMs = now;
}

String makeStatusLine() {
  String s;
  s += "fan1_duty=" + String(fan1DutyPercent);
  s += ",fan1_rpm=" + String(fan1Rpm);
  s += ",fan2_duty=" + String(fan2DutyPercent);
  s += ",fan2_rpm=" + String(fan2Rpm);
  s += ",mode=" + String(autoMode ? "auto" : "manual");
  return s;
}

void notifyStatusEverySecond() {
  static uint32_t lastMs = 0;

  uint32_t now = millis();
  if (now - lastMs < 1000) return;

  String status = makeStatusLine();
  Serial.println(status);

  if (statusCharacteristic) {
    statusCharacteristic->setValue(status.c_str());
    statusCharacteristic->notify();
  }

  lastMs = now;
}

// -------------------- BLE command handling --------------------

class CommandCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& connInfo) override {
    std::string value = characteristic->getValue();
    String cmd = String(value.c_str());
    cmd.trim();
    cmd.toUpperCase();

    Serial.print("BLE cmd: ");
    Serial.println(cmd);

    if (cmd == "AUTO") {
      autoMode = true;
      return;
    }

    if (cmd == "STATUS") {
      if (statusCharacteristic) {
        String status = makeStatusLine();
        statusCharacteristic->setValue(status.c_str());
        statusCharacteristic->notify();
      }
      return;
    }

    if (cmd.startsWith("BOTH ")) {
      autoMode = false;
      int percent = cmd.substring(5).toInt();
      setFanDutyPercent(1, clampPercent(percent));
      setFanDutyPercent(2, clampPercent(percent));
      return;
    }

    if (cmd.startsWith("MAN ")) {
      autoMode = false;

      // Format: MAN 1 70
      int firstSpace = cmd.indexOf(' ');
      int secondSpace = cmd.indexOf(' ', firstSpace + 1);
      if (secondSpace < 0) return;

      int fan = cmd.substring(firstSpace + 1, secondSpace).toInt();
      int percent = cmd.substring(secondSpace + 1).toInt();

      if (fan == 1 || fan == 2) {
        setFanDutyPercent(fan, clampPercent(percent));
      }
      return;
    }
  }
};

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& connInfo) override {
    (void)server;
    Serial.print("BLE client connected: ");
    Serial.println(connInfo.getAddress().toString().c_str());
  }

  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& connInfo, int reason) override {
    (void)server;
    Serial.print("BLE client disconnected: ");
    Serial.print(connInfo.getAddress().toString().c_str());
    Serial.print(", reason=");
    Serial.println(reason);
    Serial.println("BLE advertising will restart.");
  }
};

// -------------------- BLE setup --------------------

void setupBle() {
  Serial.println("BLE init...");
  NimBLEDevice::init(BLE_DEVICE_NAME);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);

  NimBLEService* service = server->createService("6e400001-b5a3-f393-e0a9-e50e24dcca9e");

  // Write-Characteristic: Handy/App -> ESP32
  NimBLECharacteristic* commandCharacteristic = service->createCharacteristic(
    "6e400002-b5a3-f393-e0a9-e50e24dcca9e",
    NIMBLE_PROPERTY::WRITE
  );
  commandCharacteristic->setCallbacks(new CommandCallbacks());

  // Notify-Characteristic: ESP32 -> Handy/App
  statusCharacteristic = service->createCharacteristic(
    "6e400003-b5a3-f393-e0a9-e50e24dcca9e",
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  statusCharacteristic->setValue("ready");

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->enableScanResponse(true);
  advertising->setName(BLE_DEVICE_NAME);
  advertising->addServiceUUID(service->getUUID());
  bool advertisingStarted = advertising->start();

  Serial.print("BLE advertising ");
  Serial.print(advertisingStarted ? "started" : "failed to start");
  Serial.print(" as ");
  Serial.println(BLE_DEVICE_NAME);
}

// -------------------- Setup / Loop --------------------

void setup() {
  Serial.begin(115200);
  delay(500);

  // Tacho-Flanken werden per ESP32-PCNT-Hardware gezaehlt.
  setupTachCounter(FAN1_TACH_PIN, FAN1_TACH_PCNT_UNIT);
  setupTachCounter(FAN2_TACH_PIN, FAN2_TACH_PCNT_UNIT);

  analogReadResolution(12);
  analogSetPinAttenuation(FAN1_POT_PIN, ADC_11db);
  analogSetPinAttenuation(FAN2_POT_PIN, ADC_11db);

  // PWM initialisieren
  setupFanPwm(FAN1_PWM_PIN, FAN1_PWM_CHANNEL);
  setupFanPwm(FAN2_PWM_PIN, FAN2_PWM_CHANNEL);

  // Anlaufkick
  setFanDutyPercent(1, 100);
  setFanDutyPercent(2, 100);
  delay(1000);

  setFanDutyPercent(1, 40);
  setFanDutyPercent(2, 40);

  setupBle();

  Serial.println("Lüftersteuerung gestartet.");
}

void loop() {
  updateRpmEverySecond();

  if (autoMode) {
    uint8_t fan1 = clampPercent(readPotPercentSmoothed(1, FAN1_POT_PIN) + fan1OffsetPercent);
    uint8_t fan2 = clampPercent(readPotPercentSmoothed(2, FAN2_POT_PIN) + fan2OffsetPercent);

    setFanDutyPercent(1, fan1);
    setFanDutyPercent(2, fan2);
  }

  notifyStatusEverySecond();

  delay(10);
}
