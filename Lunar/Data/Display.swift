//
//  Display.swift
//  Lunar
//
//  Created by Alin on 05/12/2017.
//  Copyright © 2017 Alin. All rights reserved.
//

import Cocoa
import SwiftDate

let MIN_BRIGHTNESS: UInt8 = 0
let MAX_BRIGHTNESS: UInt8 = 100
let MIN_CONTRAST: UInt8 = 0
let MAX_CONTRAST: UInt8 = 100
let GENERIC_DISPLAY_ID: CGDirectDisplayID = 0
let GENERIC_DISPLAY: Display = Display(id: GENERIC_DISPLAY_ID, serial: "GENERIC_SERIAL", name: "No Display", minBrightness: 0, maxBrightness: 100, minContrast: 0, maxContrast: 100, context: datastore.context)
let MAX_SMOOTH_STEP_TIME_NS: UInt64 = 10 * 1_000_000 // 10ms

class Display: NSManagedObject {
    @NSManaged var id: CGDirectDisplayID
    @NSManaged var serial: String
    @NSManaged var name: String
    @NSManaged var adaptive: Bool

    @NSManaged var lockedBrightness: Bool
    @NSManaged var lockedContrast: Bool

    @NSManaged var minBrightness: NSNumber
    @NSManaged var maxBrightness: NSNumber

    @NSManaged var minContrast: NSNumber
    @NSManaged var maxContrast: NSNumber

    @NSManaged var brightness: NSNumber
    @NSManaged var contrast: NSNumber

    var active: Bool = false
    var observers: [NSKeyValueObservation] = []
    var datastoreObservers: [NSKeyValueObservation] = []
    var onReadapt: (() -> Void)?
    var smoothStep = 1

    convenience init(id: CGDirectDisplayID, serial: String? = nil, name: String? = nil, active: Bool = false, minBrightness: UInt8 = MIN_BRIGHTNESS, maxBrightness: UInt8 = MAX_BRIGHTNESS, minContrast: UInt8 = MIN_CONTRAST, maxContrast: UInt8 = MAX_CONTRAST, context: NSManagedObjectContext? = nil) {
        let context = context ?? datastore.context
        let entity = NSEntityDescription.entity(forEntityName: "Display", in: context)!
        if id != GENERIC_DISPLAY_ID {
            self.init(entity: entity, insertInto: context)
        } else {
            self.init(entity: entity, insertInto: nil)
        }
        self.id = id
        if let name = name, !name.isEmpty {
            self.name = name
        } else {
            self.name = DDC.getDisplayName(for: id)
        }
        self.serial = (serial ?? DDC.getDisplaySerial(for: id)).stripped
        self.active = active
        lockedBrightness = false
        lockedContrast = false
        if id != GENERIC_DISPLAY_ID {
            self.minBrightness = NSNumber(value: minBrightness)
            self.maxBrightness = NSNumber(value: maxBrightness)
            self.minContrast = NSNumber(value: minContrast)
            self.maxContrast = NSNumber(value: maxContrast)
        }
    }

    func resetName() {
        name = DDC.getDisplayName(for: id)
    }

    func readapt<T>(display: Display, change: NSKeyValueObservedChange<T>) {
        if let readaptListener = onReadapt {
            readaptListener()
        }
        if let newVal = change.newValue as? NSNumber,
            let oldVal = change.oldValue as? NSNumber {
            if display.adaptive, newVal != oldVal {
                switch brightnessAdapter.mode {
                case .location:
                    display.adapt(moment: brightnessAdapter.moment)
                case .sync:
                    if let brightness = brightnessAdapter.getBuiltinDisplayBrightness() {
                        log.verbose("Builtin Display Brightness: \(brightness)")
                        display.adapt(percent: Double(brightness))
                    } else {
                        log.verbose("Can't get Builtin Display Brightness")
                    }
                default:
                    return
                }
            }
        }
    }

    func smoothTransition(from currentValue: UInt8, to value: UInt8, adjust: @escaping ((UInt8) -> Void)) {
        var steps = abs(value.distance(to: currentValue))

        var step: Int
        let minVal: UInt8
        let maxVal: UInt8
        if value < currentValue {
            step = cap(-smoothStep, minVal: -steps, maxVal: -1)
            minVal = value
            maxVal = currentValue
        } else {
            step = cap(smoothStep, minVal: 1, maxVal: steps)
            minVal = currentValue
            maxVal = value
        }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now()) {
            let startTime = DispatchTime.now()
            var elapsedTime: UInt64
            var elapsedSeconds: String

            adjust(UInt8(Int(currentValue) + step))

            elapsedTime = DispatchTime.now().rawValue - startTime.rawValue
            elapsedSeconds = String(format: "%.3f", Double(elapsedTime) / 1_000_000_000.0)
            log.debug("It took \(elapsedTime)ns (\(elapsedSeconds)s) to change brightness by \(step)")

            steps = steps - abs(step)
            if steps <= 0 {
                adjust(value)
                return
            }

            self.smoothStep = cap(Int(elapsedTime / MAX_SMOOTH_STEP_TIME_NS), minVal: 1, maxVal: 100)
            if value < currentValue {
                step = cap(-self.smoothStep, minVal: -steps, maxVal: -1)
            } else {
                step = cap(self.smoothStep, minVal: 1, maxVal: steps)
            }

            for newValue in stride(from: Int(currentValue), through: Int(value), by: step) {
                adjust(cap(UInt8(newValue), minVal: minVal, maxVal: maxVal))
            }
            adjust(value)

            elapsedTime = DispatchTime.now().rawValue - startTime.rawValue
            elapsedSeconds = String(format: "%.3f", Double(elapsedTime) / 1_000_000_000.0)
            log.debug("It took \(elapsedTime)ns (\(elapsedSeconds)s) to change brightness from \(currentValue) to \(value) by \(step)")
        }
    }

    func addObservers() {
        datastoreObservers = [
            datastore.defaults.observe(\UserDefaults.brightnessLimitMin, options: [.new, .old], changeHandler: { _, v in self.readapt(display: self, change: v) }),
            datastore.defaults.observe(\UserDefaults.brightnessLimitMax, options: [.new, .old], changeHandler: { _, v in self.readapt(display: self, change: v) }),
            datastore.defaults.observe(\UserDefaults.contrastLimitMin, options: [.new, .old], changeHandler: { _, v in self.readapt(display: self, change: v) }),
            datastore.defaults.observe(\UserDefaults.contrastLimitMax, options: [.new, .old], changeHandler: { _, v in self.readapt(display: self, change: v) }),
        ]
        observers = [
            observe(\.minBrightness, options: [.new, .old], changeHandler: readapt),
            observe(\.maxBrightness, options: [.new, .old], changeHandler: readapt),
            observe(\.minContrast, options: [.new, .old], changeHandler: readapt),
            observe(\.maxContrast, options: [.new, .old], changeHandler: readapt),
            observe(\.brightness, options: [.new, .old], changeHandler: { _, change in
                if let newBrightness = change.newValue, self.id != GENERIC_DISPLAY_ID {
                    var brightness: UInt8
                    if brightnessAdapter.mode == AdaptiveMode.manual {
                        brightness = cap(newBrightness.uint8Value, minVal: 0, maxVal: 100)
                    } else {
                        brightness = cap(newBrightness.uint8Value, minVal: self.minBrightness.uint8Value, maxVal: self.maxBrightness.uint8Value)
                    }
                    let currentValue = change.oldValue!.uint8Value

                    if datastore.defaults.smoothTransition {
                        self.smoothTransition(from: currentValue, to: brightness) { newValue in
                            _ = DDC.setBrightness(for: self.id, brightness: newValue)
                        }
                    } else {
                        _ = DDC.setBrightness(for: self.id, brightness: brightness)
                    }

                    log.debug("\(self.name): Set brightness to \(brightness)")
                }
            }),
            observe(\.contrast, options: [.new, .old], changeHandler: { _, change in
                if let newContrast = change.newValue, self.id != GENERIC_DISPLAY_ID {
                    var contrast: UInt8
                    if brightnessAdapter.mode == AdaptiveMode.manual {
                        contrast = cap(newContrast.uint8Value, minVal: 0, maxVal: 100)
                    } else {
                        contrast = cap(newContrast.uint8Value, minVal: self.minContrast.uint8Value, maxVal: self.maxContrast.uint8Value)
                    }
                    let currentValue = change.oldValue!.uint8Value

                    if datastore.defaults.smoothTransition {
                        self.smoothTransition(from: currentValue, to: contrast) { newValue in
                            _ = DDC.setContrast(for: self.id, contrast: newValue)
                        }
                    } else {
                        _ = DDC.setContrast(for: self.id, contrast: contrast)
                    }

                    log.debug("\(self.name): Set contrast to \(contrast)")
                }
            }),
        ]
    }

    func removeObservers() {
        observers.removeAll(keepingCapacity: true)
        datastoreObservers.removeAll(keepingCapacity: true)
    }

    func computeBrightness(from percent: Double, offset: Int? = nil, appOffset: Int = 0, minVal: Double? = nil, maxVal: Double? = nil) -> NSNumber {
        let minBrightness = minVal ?? self.minBrightness.doubleValue
        let maxBrightness = maxVal ?? self.maxBrightness.doubleValue
        let offset = offset ?? datastore.defaults.brightnessOffset

        var factor = 1.0
        if offset > 0 {
            factor = 1.0 - (Double(offset) / 100.0)
        } else if offset < 0 {
            factor = 1.0 - (Double(offset) / 10.0)
        }
        var brightness = pow(((percent / 100.0) * (maxBrightness - minBrightness) + minBrightness) / 100.0, factor) * 100.0
        brightness = cap(brightness, minVal: minBrightness, maxVal: maxBrightness)

        if appOffset > 0 {
            brightness = cap(brightness + Double(appOffset), minVal: minBrightness, maxVal: maxBrightness)
        }
        return NSNumber(value: Int(brightness))
    }

    func computeContrast(from percent: Double, offset: Int? = nil, appOffset: Int = 0, minVal: Double? = nil, maxVal: Double? = nil) -> NSNumber {
        let minContrast = minVal ?? self.minContrast.doubleValue
        let maxContrast = maxVal ?? self.maxContrast.doubleValue
        let offset = offset ?? datastore.defaults.contrastOffset

        var factor = 1.0
        if offset > 0 {
            factor = 1.0 - (Double(offset) / 100.0)
        } else if offset < 0 {
            factor = 1.0 + (Double(-offset) / 100.0)
        }
        var contrast = pow(((percent / 100.0) * (maxContrast - minContrast) + minContrast) / 100.0, factor) * 100.0
        contrast = cap(contrast, minVal: minContrast, maxVal: maxContrast)

        if appOffset > 0 {
            contrast = cap(contrast + Double(appOffset), minVal: minContrast, maxVal: maxContrast)
        }
        return NSNumber(value: Int(contrast))
    }

    func getBrightnessContrast(
        moment: Moment,
        hour: Int? = nil,
        minute: Int = 0,
        minBrightness: UInt8? = nil,
        maxBrightness: UInt8? = nil,
        minContrast: UInt8? = nil,
        maxContrast: UInt8? = nil,
        daylightExtension: Int? = nil,
        noonDuration: Int? = nil,
        brightnessOffset: Int? = nil,
        contrastOffset: Int? = nil,
        appBrightnessOffset: Int = 0,
        appContrastOffset: Int = 0
    ) -> (NSNumber, NSNumber) {
        var now = DateInRegion().convertTo(region: Region.local)
        if let hour = hour {
            now = now.dateBySet(hour: hour, min: minute, secs: 0)!
        }
        let seconds = 60.0
        let minBrightness = minBrightness ?? self.minBrightness.uint8Value
        let maxBrightness = maxBrightness ?? self.maxBrightness.uint8Value
        let minContrast = minContrast ?? self.minContrast.uint8Value
        let maxContrast = maxContrast ?? self.maxContrast.uint8Value
        var newBrightness = NSNumber(value: minBrightness)
        var newContrast = NSNumber(value: minContrast)
        let daylightExtension = daylightExtension ?? datastore.defaults.daylightExtensionMinutes
        let noonDuration = noonDuration ?? datastore.defaults.noonDurationMinutes

        let daylightStart = moment.sunrise - daylightExtension.minutes
        let daylightEnd = moment.sunset + daylightExtension.minutes

        let noonStart = moment.solarNoon - (noonDuration / 2).minutes
        let noonEnd = moment.solarNoon + (noonDuration / 2).minutes

        switch now {
        case daylightStart ... noonStart:
            let firstHalfDayMinutes = ((noonStart - daylightStart) / seconds)
            let minutesSinceSunrise = ((now - daylightStart) / seconds)
            let percent = (minutesSinceSunrise / firstHalfDayMinutes) * 100
            newBrightness = computeBrightness(from: percent, offset: brightnessOffset, appOffset: appBrightnessOffset, minVal: Double(minBrightness), maxVal: Double(maxBrightness))
            newContrast = computeContrast(from: percent, offset: contrastOffset, appOffset: appContrastOffset, minVal: Double(minContrast), maxVal: Double(maxContrast))
        case noonEnd ... daylightEnd:
            let secondHalfDayMinutes = ((daylightEnd - noonEnd) / seconds)
            let minutesSinceNoon = ((now - noonEnd) / seconds)
            let percent = ((secondHalfDayMinutes - minutesSinceNoon) / secondHalfDayMinutes) * 100
            newBrightness = computeBrightness(from: percent, offset: brightnessOffset, appOffset: appBrightnessOffset, minVal: Double(minBrightness), maxVal: Double(maxBrightness))
            newContrast = computeContrast(from: percent, offset: contrastOffset, appOffset: appContrastOffset, minVal: Double(minContrast), maxVal: Double(maxContrast))
        case noonStart ... noonEnd:
            newBrightness = NSNumber(value: maxBrightness)
            newContrast = NSNumber(value: maxContrast)
        default:
            newBrightness = NSNumber(value: minBrightness)
            newContrast = NSNumber(value: minContrast)
        }

        if appBrightnessOffset > 0 {
            newBrightness = NSNumber(value: min(newBrightness.intValue + appBrightnessOffset, Int(MAX_BRIGHTNESS)))
        }
        if appContrastOffset > 0 {
            newContrast = NSNumber(value: min(newContrast.intValue + appContrastOffset, Int(MAX_CONTRAST)))
        }
        return (newBrightness, newContrast)
    }

    func adapt(moment: Moment? = nil, app: AppException? = nil, percent: Double? = nil) {
        if !adaptive {
            return
        }

        var newBrightness: NSNumber = 0
        var newContrast: NSNumber = 0
        if let moment = moment {
            (newBrightness, newContrast) = getBrightnessContrast(moment: moment, appBrightnessOffset: app?.brightness.intValue ?? 0, appContrastOffset: app?.contrast.intValue ?? 0)
        } else if let percent = percent {
            newBrightness = computeBrightness(from: percent, appOffset: app?.brightness.intValue ?? 0)
            newContrast = computeContrast(from: percent, appOffset: app?.contrast.intValue ?? 0)
        }

        var changed = false
        if lockedBrightness {
            setValue(brightness, forKey: "brightness")
        } else if brightness != newBrightness {
            setValue(newBrightness, forKey: "brightness")
            changed = true
        }

        if lockedContrast {
            setValue(contrast, forKey: "contrast")
        } else if contrast != newContrast {
            setValue(newContrast, forKey: "contrast")
            changed = true
        }
        if changed {
            log.info("\n\(name):\n\tBrightness: \(newBrightness)\n\tContrast: \(newContrast)")
        }
    }
}
