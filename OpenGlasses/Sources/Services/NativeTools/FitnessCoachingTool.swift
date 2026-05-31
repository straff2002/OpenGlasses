import Foundation
import HealthKit
import UIKit
import Vision

/// Real-time fitness coaching: exercise tracking, rep counting, form feedback via TTS,
/// and HealthKit workout logging. Uses Vision pose estimation when camera frames are available.
struct FitnessCoachingTool: NativeTool {
    let name = "fitness_coach"
    let description = "Fitness coaching: start/stop workout tracking, log exercises, get rep counts, check form via camera, and view workout history from HealthKit."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: start_workout, stop_workout, log_exercise, check_form, workout_history, step_goal",
                "enum": ["start_workout", "stop_workout", "log_exercise", "check_form", "workout_history", "step_goal"]
            ],
            "workout_type": [
                "type": "string",
                "description": "Type of workout (e.g., 'strength', 'cardio', 'yoga', 'running', 'cycling')"
            ],
            "exercise": [
                "type": "string",
                "description": "Exercise name for logging (e.g., 'push-ups', 'squats', 'lunges')"
            ],
            "reps": [
                "type": "integer",
                "description": "Number of reps performed"
            ],
            "sets": [
                "type": "integer",
                "description": "Number of sets performed"
            ],
            "weight": [
                "type": "number",
                "description": "Weight used in lbs or kg"
            ],
            "duration_minutes": [
                "type": "integer",
                "description": "Duration in minutes for cardio exercises"
            ],
            "daily_step_goal": [
                "type": "integer",
                "description": "Daily step goal to set"
            ]
        ],
        "required": ["action"]
    ]

    private let healthStore = HKHealthStore()
    private static var activeWorkout: ActiveWorkout?

    struct ActiveWorkout {
        let type: String
        let startDate: Date
        var exercises: [(name: String, sets: Int, reps: Int, weight: Double?)]
        var caloriesEstimate: Double
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "No action specified."
        }

        switch action {
        case "start_workout":
            return await startWorkout(args: args)
        case "stop_workout":
            return await stopWorkout()
        case "log_exercise":
            return logExercise(args: args)
        case "check_form":
            return "Form checking requires a camera frame. Ask the user to show their exercise form to the camera and I'll analyze the pose."
        case "workout_history":
            return await getWorkoutHistory()
        case "step_goal":
            return handleStepGoal(args: args)
        default:
            return "Unknown action: \(action)"
        }
    }

    // MARK: - Workout Management

    private func startWorkout(args: [String: Any]) async -> String {
        let workoutType = args["workout_type"] as? String ?? "general"

        if Self.activeWorkout != nil {
            return "A workout is already in progress. Stop it first with stop_workout, or log exercises to the current session."
        }

        Self.activeWorkout = ActiveWorkout(
            type: workoutType,
            startDate: Date(),
            exercises: [],
            caloriesEstimate: 0
        )

        return "Started a \(workoutType) workout session. Log exercises as you go with log_exercise, and I'll track everything. Say 'stop workout' when you're done."
    }

    private func stopWorkout() async -> String {
        guard let workout = Self.activeWorkout else {
            return "No active workout to stop."
        }

        let duration = Date().timeIntervalSince(workout.startDate)
        let durationMinutes = Int(duration / 60)

        // Build summary
        var summary = "Workout complete! \(workout.type.capitalized) session: \(durationMinutes) minutes."

        if !workout.exercises.isEmpty {
            let exerciseList = workout.exercises.map { ex in
                var desc = "\(ex.name): \(ex.sets) sets x \(ex.reps) reps"
                if let w = ex.weight { desc += " at \(Int(w)) lbs" }
                return desc
            }
            summary += " Exercises: \(exerciseList.joined(separator: "; "))."
        }

        // Estimate calories
        let estimatedCalories = estimateCalories(workout: workout, durationMinutes: durationMinutes)
        summary += " Estimated calories burned: \(Int(estimatedCalories))."

        // Try to save to HealthKit
        let saved = await saveWorkoutToHealthKit(workout: workout, duration: duration, calories: estimatedCalories)
        if saved {
            summary += " Saved to Apple Health."
        }

        Self.activeWorkout = nil

        // Also save to local notes for reference
        saveWorkoutNote(summary: summary)

        return summary
    }

    private func logExercise(args: [String: Any]) -> String {
        guard var workout = Self.activeWorkout else {
            return "No active workout. Start one first with start_workout."
        }

        let exercise = args["exercise"] as? String ?? "exercise"
        let reps = args["reps"] as? Int ?? 0
        let sets = args["sets"] as? Int ?? 1
        let weight = args["weight"] as? Double

        workout.exercises.append((name: exercise, sets: sets, reps: reps, weight: weight))
        Self.activeWorkout = workout

        var response = "Logged: \(exercise), \(sets) set\(sets == 1 ? "" : "s") of \(reps) rep\(reps == 1 ? "" : "s")"
        if let w = weight {
            response += " at \(Int(w)) lbs"
        }
        response += ". Total exercises this session: \(workout.exercises.count)."
        return response
    }

    // MARK: - HealthKit

    private func getWorkoutHistory() async -> String {
        // Apple Guideline 5.1.3: HealthKit data may only be disclosed to a third
        // party (here, the LLM provider that receives this tool result) with the
        // user's explicit consent. Gate the read behind an opt-in toggle that
        // defaults off, rather than silently transmitting Health records.
        guard Config.shareHealthDataWithAI else {
            return "Sharing Apple Health data with the AI is turned off. The user can enable \"Share Health data with AI\" in Settings → Privacy to let me read and discuss their workout history."
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            return "HealthKit is not available on this device."
        }

        let workoutType = HKObjectType.workoutType()

        // Request read access
        let readTypes: Set<HKObjectType> = [workoutType]
        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            return "Unable to access HealthKit: \(error.localizedDescription)"
        }

        // Query last 7 days of workouts
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -7, to: endDate) else {
            return "Couldn't calculate date range."
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: 10, sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error = error {
                    continuation.resume(returning: "HealthKit query failed: \(error.localizedDescription)")
                    return
                }

                guard let workouts = results as? [HKWorkout], !workouts.isEmpty else {
                    continuation.resume(returning: "No workouts found in the last 7 days.")
                    return
                }

                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short

                let summaries = workouts.prefix(5).map { w -> String in
                    let type = w.workoutActivityType.displayName
                    let duration = Int(w.duration / 60)
                    let date = formatter.string(from: w.startDate)
                    let calorieStats = w.statistics(for: HKQuantityType(.activeEnergyBurned))
                    let calories = calorieStats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                    return "\(date): \(type), \(duration) min, \(Int(calories)) cal"
                }

                continuation.resume(returning: "Recent workouts: \(summaries.joined(separator: ". "))")
            }
            healthStore.execute(query)
        }
    }

    private func saveWorkoutToHealthKit(workout: ActiveWorkout, duration: TimeInterval, calories: Double) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }

        let workoutType = HKObjectType.workoutType()
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!

        do {
            try await healthStore.requestAuthorization(toShare: [workoutType, energyType], read: [])
        } catch {
            return false
        }

        let activityType = mapWorkoutType(workout.type)
        let config = HKWorkoutConfiguration()
        config.activityType = activityType

        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config, device: nil)

        do {
            try await builder.beginCollection(at: workout.startDate)

            let calorieQuantity = HKQuantity(unit: .kilocalorie(), doubleValue: calories)
            let calorieSample = HKQuantitySample(
                type: HKQuantityType(.activeEnergyBurned),
                quantity: calorieQuantity,
                start: workout.startDate,
                end: Date()
            )
            try await builder.addSamples([calorieSample])
            try await builder.endCollection(at: Date())
            try await builder.addMetadata(["OpenGlasses": true])
            try await builder.finishWorkout()
            return true
        } catch {
            print("🏋️ Failed to save workout: \(error)")
            return false
        }
    }

    private func handleStepGoal(args: [String: Any]) -> String {
        if let goal = args["daily_step_goal"] as? Int {
            UserDefaults.standard.set(goal, forKey: "fitnessStepGoal")
            return "Daily step goal set to \(goal.formatted()) steps."
        } else {
            let current = UserDefaults.standard.integer(forKey: "fitnessStepGoal")
            if current > 0 {
                return "Your daily step goal is \(current.formatted()) steps. Use the step_count tool to check today's progress."
            } else {
                return "No step goal set. Provide a daily_step_goal number to set one."
            }
        }
    }

    // MARK: - Helpers

    private func estimateCalories(workout: ActiveWorkout, durationMinutes: Int) -> Double {
        // Rough MET-based estimates
        let met: Double
        switch workout.type.lowercased() {
        case "strength", "weight training", "weights":
            met = 5.0
        case "cardio", "hiit":
            met = 8.0
        case "yoga", "stretching":
            met = 3.0
        case "running", "run":
            met = 9.8
        case "cycling", "bike":
            met = 7.5
        case "walking", "walk":
            met = 3.5
        default:
            met = 5.0
        }
        // Calories = MET * weight(kg) * hours. Assume 70kg average.
        let hours = Double(durationMinutes) / 60.0
        return met * 70.0 * hours
    }

    private func mapWorkoutType(_ type: String) -> HKWorkoutActivityType {
        switch type.lowercased() {
        case "strength", "weight training", "weights": return .traditionalStrengthTraining
        case "cardio", "hiit": return .highIntensityIntervalTraining
        case "yoga": return .yoga
        case "running", "run": return .running
        case "cycling", "bike": return .cycling
        case "walking", "walk": return .walking
        case "swimming", "swim": return .swimming
        default: return .other
        }
    }

    private func saveWorkoutNote(summary: String) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let key = "saved_notes"
        var notes = UserDefaults.standard.stringArray(forKey: key) ?? []
        let note = "[\(formatter.string(from: Date()))] Workout: \(summary)"
        notes.append(note)
        UserDefaults.standard.set(notes, forKey: key)
    }
}

// MARK: - HKWorkoutActivityType Display Name

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .traditionalStrengthTraining: return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .swimming: return "Swimming"
        default: return "Workout"
        }
    }
}

// MARK: - Pose Analysis (Vision Framework)

/// Static utility for analyzing exercise form from camera frames.
/// Called by the LLM when the user asks for form checking during a workout.
enum PoseAnalyzer {
    /// Analyze a UIImage for body pose and return form feedback.
    static func analyzeForm(image: UIImage, exercise: String) -> String {
        guard let cgImage = image.cgImage else {
            return "Couldn't process the image for pose analysis."
        }

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            guard let observation = request.results?.first else {
                return "No body pose detected in the image. Make sure your full body is visible to the camera."
            }

            return analyzePoseForExercise(observation: observation, exercise: exercise)
        } catch {
            return "Pose analysis failed: \(error.localizedDescription)"
        }
    }

    private static func analyzePoseForExercise(observation: VNHumanBodyPoseObservation, exercise: String) -> String {
        // Extract key joint positions
        guard let leftShoulder = try? observation.recognizedPoint(.leftShoulder),
              let rightShoulder = try? observation.recognizedPoint(.rightShoulder),
              let leftElbow = try? observation.recognizedPoint(.leftElbow),
              let _ = try? observation.recognizedPoint(.rightElbow),
              let leftWrist = try? observation.recognizedPoint(.leftWrist),
              let _ = try? observation.recognizedPoint(.rightWrist),
              let leftHip = try? observation.recognizedPoint(.leftHip),
              let rightHip = try? observation.recognizedPoint(.rightHip),
              let leftKnee = try? observation.recognizedPoint(.leftKnee),
              let _ = try? observation.recognizedPoint(.rightKnee),
              let leftAnkle = try? observation.recognizedPoint(.leftAnkle),
              let _ = try? observation.recognizedPoint(.rightAnkle) else {
            return "Couldn't detect enough body joints. Try to ensure your full body is visible from a side angle."
        }

        let exerciseLower = exercise.lowercased()
        var feedback: [String] = []

        if exerciseLower.contains("squat") {
            // Check knee angle
            let kneeAngle = angle(a: leftHip.location, b: leftKnee.location, c: leftAnkle.location)
            if kneeAngle > 120 {
                feedback.append("Go deeper in your squat. Try to get your thighs parallel to the ground.")
            } else if kneeAngle < 70 {
                feedback.append("You're going very deep. Make sure your knees don't go too far past your toes.")
            } else {
                feedback.append("Good squat depth.")
            }

            // Check back angle
            let backAngle = angle(a: leftShoulder.location, b: leftHip.location, c: leftKnee.location)
            if backAngle < 60 {
                feedback.append("Try to keep your chest up more. You're leaning forward too much.")
            }

        } else if exerciseLower.contains("push") {
            let elbowAngle = angle(a: leftShoulder.location, b: leftElbow.location, c: leftWrist.location)
            if elbowAngle > 160 {
                feedback.append("At the top position. Arms are extended well.")
            } else if elbowAngle < 100 {
                feedback.append("Good depth on the push-up.")
            }

            // Check body alignment
            let bodyAngle = angle(a: leftShoulder.location, b: leftHip.location, c: leftAnkle.location)
            if bodyAngle < 160 {
                feedback.append("Keep your body straighter. Your hips seem to be sagging or piking.")
            } else {
                feedback.append("Good body alignment.")
            }

        } else if exerciseLower.contains("lunge") {
            let frontKneeAngle = angle(a: leftHip.location, b: leftKnee.location, c: leftAnkle.location)
            if frontKneeAngle > 110 {
                feedback.append("Step deeper into your lunge.")
            } else if frontKneeAngle < 80 {
                feedback.append("Good lunge depth. Make sure your front knee stays over your ankle.")
            }

        } else {
            // Generic feedback
            let shoulderWidth = abs(leftShoulder.location.x - rightShoulder.location.x)
            let hipWidth = abs(leftHip.location.x - rightHip.location.x)
            feedback.append("I can see your pose. Shoulders look \(shoulderWidth > 0.15 ? "wide and stable" : "a bit narrow").")
            feedback.append("Overall stance looks \(hipWidth > 0.1 ? "balanced" : "narrow, try widening your feet").")
        }

        if feedback.isEmpty {
            return "Pose detected but I need a clearer view to give specific feedback on \(exercise). Try a side angle."
        }

        return "Form analysis for \(exercise): \(feedback.joined(separator: " "))"
    }

    /// Calculate angle at point b between vectors ba and bc, in degrees.
    private static func angle(a: CGPoint, b: CGPoint, c: CGPoint) -> Double {
        let ba = CGPoint(x: a.x - b.x, y: a.y - b.y)
        let bc = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let dot = ba.x * bc.x + ba.y * bc.y
        let magBA = sqrt(ba.x * ba.x + ba.y * ba.y)
        let magBC = sqrt(bc.x * bc.x + bc.y * bc.y)
        guard magBA > 0, magBC > 0 else { return 0 }
        let cosAngle = max(-1.0, min(1.0, dot / (magBA * magBC)))
        return acos(cosAngle) * 180.0 / .pi
    }
}
