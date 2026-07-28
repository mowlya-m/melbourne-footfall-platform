output "state_machine_arn" {
  description = "The batch orchestrator state machine."
  value       = aws_sfn_state_machine.orchestrator.arn
}

output "state_machine_name" {
  description = "Name of the orchestrator, for manual execution."
  value       = aws_sfn_state_machine.orchestrator.name
}
