#
# Copyright (C) 2014 - present Instructure, Inc.
#
# This file is part of Rollcall.
#
# Rollcall is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Rollcall is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

class AttendanceAssignment
  include CanvasCache

  attr_accessor :canvas, :course_id, :tool_launch_url, :tool_consumer_instance_guid

  def initialize(canvas, course_id, tool_launch_url, tool_consumer_instance_guid)
    @canvas = canvas
    @course_id = course_id
    @tool_launch_url = tool_launch_url
    @tool_consumer_instance_guid = tool_consumer_instance_guid
  end

  def fetch_or_create
    assignment = fetch_from_cache

    return assignment if assignment

    Redis::Lock.new(lock_key, :expiration => 120, :timeout => 0.5).lock do
      # expiration and timeout are in seconds
      assignment = fetch || create
    end

    cache_assignment(assignment.to_json) if assignment

    assignment
  end

  def fetch(try_update: true)
    assignments = canvas.get_assignments(course_id)
    assignment = assignments&.find { |a| a['name'] == name }
    update_cached_assignment_if_needed(assignment) if assignment && try_update
    assignment
  end

  def fetch_from_cache
    cached_assignment = redis.get(cache_key)
    cached_assignment.blank? ? nil : JSON.parse(cached_assignment)
  end

  def create
    options = {
      name: name,
      grading_type: "percent",
      points_possible: 100,
      published: true,
      submission_types: ['external_tool'],
      external_tool_tag_attributes: {
        url: tool_launch_url,
        new_tab: false
      },
      omit_from_final_grade: course_config_omit_from_final_grade
    }

    canvas.create_assignment(course_id, options)
  end

  def update_cached_assignment_if_needed(fresh_assignment)
    return nil unless fresh_assignment

    fresh_assignment_omit_from_final_grade = !!fresh_assignment['omit_from_final_grade']
    return fresh_assignment if fresh_assignment_omit_from_final_grade == course_config_omit_from_final_grade

    CourseConfig.
      find_by(course_id: course_id, tool_consumer_instance_guid: tool_consumer_instance_guid).
      update!(omit_from_final_grade: fresh_assignment_omit_from_final_grade)

    course_config_omit_from_final_grade = fresh_assignment_omit_from_final_grade
    cache_assignment(fresh_assignment.to_json)
    fresh_assignment
  end

  def course_config_omit_from_final_grade
    # Doing the nil check since ||= if omit_from_final_grade was false we'd do a lookup anyway
    if @omit_from_final_grade.nil?
      @omit_from_final_grade = !!(CourseConfig.select(:omit_from_final_grade).
        find_by(course_id: course_id, tool_consumer_instance_guid: tool_consumer_instance_guid)&.omit_from_final_grade)
    end
    @omit_from_final_grade
  end

  def course_config_omit_from_final_grade=(omit_from_final_grade)
    @omit_from_final_grade = omit_from_final_grade
  end

  def name
    "Roll Call Attendance"
  end

  def submit_grade(assignment_id, student_id)
    if assignment_id.present?
      grade = StudentCourseStats.new(
        student_id,
        course_id,
        active_section_ids,
        tool_consumer_instance_guid
      ).grade
      begin
        canvas.grade_assignment(
          course_id,
          assignment_id,
          student_id,
          submission: { posted_grade: grade, submission_type: 'basic_lti_launch', url: @tool_launch_url }
        )
      rescue CanvasOauth::CanvasApi::Unauthorized
        # user is not authorized to update grades
      end
    end
  end

  def redis
    Redis.current
  end

  def base_key
    "attendance_assignment.#{@canvas.canvas_url}.course_#{@course_id}"
  end

  def lock_key
    base_key
  end

  def cache_key
    "#{base_key}:assignment_cache_ex"
  end

  def cache_assignment(assign_json)
    expiration = 15.minutes.seconds.to_i
    redis.set(cache_key, assign_json, ex: expiration)
  end

  def active_section_ids
    @active_sections_ids ||= begin
      sections = cached_sections(course_id)
      sections.map { |s| s["id"] }
    end
  end
end
